import AppKit
import Foundation

nonisolated struct XenTransferRecord: Codable, Identifiable, Sendable {
    var id = UUID()
    let clusterID: UUID
    let poolUUID: String
    let taskRef: String
    let direction: String
    let filename: String
    var status: String
}

/// URLSession streams files to disk/from disk. Session secrets are never persisted with recovery records.
nonisolated final class XenFileTransfer: NSObject, URLSessionDownloadDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let allowsUntrusted: Bool
    private let destination: URL?
    private let progress: @Sendable (Double) -> Void
    private let trustedHosts: Set<String>
    private var originalRequest: URLRequest?
    private var sourceURL: URL?
    private var redirectCount = 0
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var continuation: CheckedContinuation<Void, Error>?
    private var fileError: Error?
    private var cancellationRequested = false
    init(allowsUntrusted: Bool, destination: URL?, trustedHosts: Set<String> = [], progress: @escaping @Sendable (Double) -> Void) {
        self.allowsUntrusted = allowsUntrusted; self.destination = destination; self.trustedHosts = Set(trustedHosts.map { $0.lowercased() }); self.progress = progress
    }
    func run(request: URLRequest, source: URL?) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                self.originalRequest = request
                self.sourceURL = source
                let newTask: URLSessionTask
                if let source { newTask = session.uploadTask(with: request, fromFile: source) }
                else { newTask = session.downloadTask(with: request) }
                task = newTask
                let cancelled = cancellationRequested
                lock.unlock()
                newTask.resume()
                if cancelled { newTask.cancel() }
            }
        } onCancel: { self.cancel() }
    }
    var wasCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancellationRequested }
    func cancel() {
        lock.lock(); cancellationRequested = true; let task = task; lock.unlock(); task?.cancel()
    }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if allowsUntrusted, challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else { completionHandler(.performDefaultHandling, nil) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let originalRequest, let originalURL = originalRequest.url, let target = request.url,
              let host = target.host?.lowercased(), trustedHosts.contains(host), target.user == nil, target.password == nil,
              originalURL.scheme == target.scheme, target.path == originalURL.path,
              target.port == originalURL.port || target.port == nil || target.port == (target.scheme == "https" ? 443 : 80),
              redirectCount < 3,
              originalRequest.httpMethod == "GET" || [307, 308].contains(response.statusCode) else { completionHandler(nil); return }
        // A definitive redirect can reopen the original file, but an unknown response/restart never does.
        var parts = URLComponents(url: target, resolvingAgainstBaseURL: false)!
        let originalParts = URLComponents(url: originalURL, resolvingAgainstBaseURL: false)!
        parts.queryItems = originalParts.queryItems
        guard let url = parts.url else { completionHandler(nil); return }
        var forwarded = originalRequest
        forwarded.url = url
        redirectCount += 1
        completionHandler(forwarded)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, needNewBodyStream completionHandler: @escaping (InputStream?) -> Void) {
        completionHandler(sourceURL.flatMap { InputStream(url: $0) })
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        if totalBytesExpectedToSend > 0 { progress(Double(totalBytesSent) / Double(totalBytesExpectedToSend)) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 { progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let http = downloadTask.response as? HTTPURLResponse, http.statusCode == 200, let destination else { return }
        do {
            let partial = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).xva.partial")
            defer { try? FileManager.default.removeItem(at: partial) }
            try FileManager.default.copyItem(at: location, to: partial)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: partial)
            } else { try FileManager.default.moveItem(at: partial, to: destination) }
        } catch { fileError = error }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let pending = continuation; continuation = nil; self.task = nil; lock.unlock()
        if let error = fileError ?? error { pending?.resume(throwing: error) }
        else if let response = task.response as? HTTPURLResponse, response.statusCode == 200 { pending?.resume() }
        else { pending?.resume(throwing: XenError.transport("XVA 传输返回 HTTP \((task.response as? HTTPURLResponse)?.statusCode ?? 0)，请核对服务器任务。")) }
    }
}

extension XenClient {
    func transferContext(identity expected: XenSessionIdentity) throws -> (URL, String) {
        try requireIdentity(expected)
        return try authenticatedEndpoint()
    }
    func createTransferTask(name: String, identity expected: XenSessionIdentity) async throws -> String {
        try requireIdentity(expected)
        let result = try await submit("task.create", [.string(name), .string("inchspace XVA transfer")]).string
        guard result.hasPrefix("OpaqueRef:"), result != "OpaqueRef:NULL" else { throw XenError.unknown("未能确认传输任务标识。") }
        return result
    }
}

extension XenStore {
    func exportXVA(_ cluster: XenCluster, vm: XenRecord) async {
        var exportMode = "direct"
        if vm.state == "Running" {
            let alert = NSAlert()
            alert.messageText = "导出运行中的虚拟机"
            alert.informativeText = "可导出一致性快照，或先正常关机。导出快照会保留在快照清单中，便于核对。"
            alert.addButton(withTitle: "取消")
            if vm.permits("checkpoint") { alert.addButton(withTitle: "导出快照") }
            if XenPowerAction.shutdown.available(for: vm) { alert.addButton(withTitle: "正常关机后导出") }
            let response = alert.runModal()
            guard response != .alertFirstButtonReturn else { return }
            let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            guard alert.buttons.indices.contains(index) else { return }
            exportMode = alert.buttons[index].title == "导出快照" ? "snapshot" : "shutdown"
        } else {
            guard ["Halted", "Suspended"].contains(vm.state), vm.permits("export") else { error = "当前状态不支持导出。"; return }
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = vm.name.replacingOccurrences(of: "/", with: "-") + ".xva"
        panel.canCreateDirectories = true
        guard await panel.begin() == .OK, let url = panel.url else { return }
        await runTransfer(cluster, resource: vm, file: url, importing: false, storage: nil, exportMode: exportMode)
    }
    func importXVA(_ cluster: XenCluster, storage: XenRecord) async {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.message = "选择 XVA 文件，导入到“\(storage.name)”。"
        guard await panel.begin() == .OK, let url = panel.url else { return }
        guard url.pathExtension.lowercased() == "xva" else { error = "请选择 .xva 文件。"; return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let preview = try XenXVA.preview(url)
            let alert = NSAlert()
            alert.messageText = "导入“\(preview.name)”？"
            alert.informativeText = "\(preview.vcpus) vCPU · \(XenFormat.bytes(preview.memory)) · \(preview.disks) 块磁盘\n目标存储：\(storage.name)\n导入后请检查网卡网络，不自动启动。"
            alert.addButton(withTitle: "导入"); alert.addButton(withTitle: "取消")
            let asTemplate = NSButton(checkboxWithTitle: "导入为模板", target: nil, action: nil)
            asTemplate.sizeToFit()
            let stack = NSStackView(views: [asTemplate])
            stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
            let networks = state(cluster.id).records[.network] ?? []
            var mappings: [(String, NSPopUpButton)] = []
            for interface in preview.interfaces {
                let label = NSTextField(labelWithString: "网卡 \(interface.device) · \(interface.network)")
                label.font = .systemFont(ofSize: 12); label.lineBreakMode = .byTruncatingTail
                let picker = NSPopUpButton()
                picker.addItem(withTitle: "保留导入配置")
                for network in networks { picker.addItem(withTitle: network.name) }
                let row = NSStackView(views: [label, picker]); row.spacing = 12
                stack.addArrangedSubview(row)
                mappings.append((interface.device, picker))
            }
            stack.frame = NSRect(x: 0, y: 0, width: 460, height: 28 + mappings.count * 32)
            alert.accessoryView = stack
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            var selectedNetworks: [String: XenRecord] = [:]
            for (device, picker) in mappings where picker.indexOfSelectedItem > 0 {
                let index = picker.indexOfSelectedItem - 1
                if networks.indices.contains(index) { selectedNetworks[device] = networks[index] }
            }
            await runTransfer(cluster, resource: storage, file: url, importing: true, storage: storage, asTemplate: asTemplate.state == .on, networkMappings: selectedNetworks)
        } catch { self.error = error.localizedDescription }
    }
    private func runTransfer(_ cluster: XenCluster, resource: XenRecord, file: URL, importing: Bool, storage: XenRecord?, exportMode: String = "direct", asTemplate: Bool = false, networkMappings: [String: XenRecord] = [:]) async {
        guard fileTransfers[cluster.id] == nil, !hasActiveOperation(cluster.id) else { error = "请等待当前集群任务结束。"; return }
        let accessed = file.startAccessingSecurityScopedResource()
        defer { if accessed { file.stopAccessingSecurityScopedResource() } }
        await perform(cluster.id, title: importing ? "导入 XVA" : "导出 XVA", record: resource) { client, identity in
            var fresh = try await client.record(resource.kind, ref: resource.id)
            guard fresh.uuid == resource.uuid else { throw XenError.invalid("资源身份已变化。") }
            if !importing {
                if exportMode == "snapshot" { fresh = try await client.exportSnapshot(fresh, identity: identity) }
                else if exportMode == "shutdown" {
                    try await client.power(.shutdown, vm: fresh, identity: identity)
                    fresh = try await client.record(resource.kind, ref: resource.id)
                }
                guard ["Halted", "Suspended"].contains(fresh.state), fresh.permits("export") else { throw XenError.invalid("VM 当前不允许导出。") }
            }
            let (endpoint, session) = try await client.transferContext(identity: identity)
            let hosts = try await client.records(.host)
            let trustedHosts = Set(hosts.map { $0["address"].string } + [endpoint.host ?? ""])
            let taskRef = try await client.createTransferTask(name: importing ? "Import XVA" : "Export XVA", identity: identity)
            var record = XenTransferRecord(clusterID: cluster.id, poolUUID: identity.poolUUID, taskRef: taskRef, direction: importing ? "import" : "export", filename: file.lastPathComponent, status: "传输中")
            try self.saveTransfer(record)
            var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
            parts.path = importing ? "/import" : "/export"
            var items = [URLQueryItem(name: "session_id", value: session), URLQueryItem(name: "task_id", value: taskRef)]
            if let storage {
                items.append(contentsOf: [URLQueryItem(name: "sr_id", value: storage.id), URLQueryItem(name: "restore", value: "false"), URLQueryItem(name: "force", value: "false")])
            }
            else { items.append(URLQueryItem(name: "uuid", value: fresh.uuid)) }
            parts.queryItems = items
            guard let url = parts.url else { throw XenError.invalid("传输地址无效。") }
            var request = URLRequest(url: url)
            request.httpMethod = importing ? "PUT" : "GET"
            if importing { request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type") }
            let staging = file.deletingLastPathComponent().appendingPathComponent(file.lastPathComponent + "." + record.id.uuidString + ".partial")
            let transfer = XenFileTransfer(allowsUntrusted: cluster.allowsUntrustedCertificate, destination: importing ? nil : staging, trustedHosts: trustedHosts) { progress in
                Task { @MainActor in self.transferProgress[cluster.id] = progress }
            }
            self.fileTransfers[cluster.id] = transfer
            self.transferTaskRefs[cluster.id] = taskRef
            self.transferProgress[cluster.id] = 0
            defer { self.fileTransfers[cluster.id] = nil; self.transferTaskRefs[cluster.id] = nil; self.transferProgress[cluster.id] = nil }
            var serverCompleted = false
            do {
                var transportError: Error?
                do { try await transfer.run(request: request, source: importing ? file : nil) }
                catch { transportError = error }
                let result = try await client.waitForTask(.string(taskRef), identity: identity, timeout: 600)
                serverCompleted = true
                if importing {
                    let importedRef = try XenTaskResult.reference(result)
                    let imported = try await client.record(.vm, ref: importedRef)
                    if !transfer.wasCancelled && !networkMappings.isEmpty { try await client.remapImportedInterfaces(imported, mappings: networkMappings, identity: identity) }
                    if asTemplate && !transfer.wasCancelled && !imported["is_a_template"].boolean { try await client.convertToTemplate(imported, identity: identity) }
                }
                if !importing {
                    guard transportError == nil, FileManager.default.fileExists(atPath: staging.path) else { throw XenError.unknown("服务器任务已结束，但本地文件未确认完整。") }
                    if FileManager.default.fileExists(atPath: file.path) { _ = try FileManager.default.replaceItemAt(file, withItemAt: staging) }
                    else { try FileManager.default.moveItem(at: staging, to: file) }
                }
                record.status = importing ? "导入任务已完成，请核对 VM 配置" : "已完成"
                try self.saveTransfer(record)
            } catch {
                if !serverCompleted, let known = error as? XenError, case .api = known {
                    record.status = "服务器任务失败或已取消"
                    try? self.saveTransfer(record)
                    if !importing { try? FileManager.default.removeItem(at: staging) }
                    throw known
                }
                record.status = "结果未知，需核对服务器任务"
                try? self.saveTransfer(record)
                throw XenError.unknown("XVA 传输未确认完成。任务 \(taskRef) 已保留；不会自动重放文件。\(error.localizedDescription.replacingOccurrences(of: session, with: "[已隐藏]"))")
            }
        }
        if importing { await refresh(cluster.id, kind: .vm) }
    }
    private func saveTransfer(_ record: XenTransferRecord) throws {
        let url = transferJournalURL
        var entries: [XenTransferRecord] = []
        if FileManager.default.fileExists(atPath: url.path) { entries = try JSONDecoder().decode([XenTransferRecord].self, from: Data(contentsOf: url)) }
        entries.removeAll { $0.id == record.id }; entries.insert(record, at: 0)
        // Do not evict unresolved server tasks from the recovery journal.
        entries = entries.filter { $0.status != "已完成" } + Array(entries.filter { $0.status == "已完成" }.prefix(50))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: url, options: .atomic)
    }
    func reconcileTransfers(_ id: UUID) async {
        let url = transferJournalURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let entries = try JSONDecoder().decode([XenTransferRecord].self, from: Data(contentsOf: url))
            guard let identity = connectionIdentity(id), let client = connectionClient(id) else { return }
            for var entry in entries where entry.clusterID == id && entry.poolUUID == identity.poolUUID && entry.status != "已完成" {
                do {
                    let task = try await client.call("task.get_record", [.string(entry.taskRef)]).dictionary
                    try await client.requireIdentity(identity)
                    let status = task["status"]?.string ?? "unknown"
                    entry.status = "服务器任务：\(status)；本地文件需人工核对"
                    try saveTransfer(entry)
                    appendRecoveredActivity(id, title: "\(entry.filename) · \(entry.status)")
                } catch { appendRecoveredActivity(id, title: "\(entry.filename) · 无法核对原传输任务") }
            }
        } catch { self.error = "无法读取传输恢复记录：\(error.localizedDescription)" }
    }
}
