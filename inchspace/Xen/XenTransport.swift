import Foundation
import Security

nonisolated protocol XenTransport: Sendable {
    func send(to endpoint: URL, body: Data) async throws -> Data
}

/// Trust exceptions apply only to this connection. Redirects must be handled explicitly by the caller.
nonisolated final class XenURLTransport: NSObject, XenTransport, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let allowsUntrustedCertificate: Bool
    init(allowsUntrustedCertificate: Bool = false) { self.allowsUntrustedCertificate = allowsUntrustedCertificate }
    func send(to endpoint: URL, body: Data) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: self)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw XenError.transport("管理服务器返回 HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)。")
            }
            guard response.expectedContentLength <= 32 * 1024 * 1024 else { throw XenError.invalid("管理服务器响应过大。") }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 32 * 1024 * 1024 else { throw XenError.invalid("管理服务器响应过大。") }
                data.append(byte)
            }
            return data
        } catch let error as XenError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch {
            let nsError = error as NSError
            let certificateErrors: Set<Int> = [NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid]
            if nsError.domain == NSURLErrorDomain && certificateErrors.contains(nsError.code) {
                let detail = allowsUntrustedCertificate
                    ? "已按当前连接的证书设置尝试连接，但 TLS 校验仍失败，请检查服务器证书与 TLS 配置。"
                    : "请确认管理地址可信后，在编辑连接的高级选项中允许不受信任的服务器证书。"
                throw XenError.transport("服务器证书校验失败，尚未验证账号密码。" + detail)
            }
            throw XenError.transport("无法完成管理请求：\(nsError.localizedDescription)")
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Never forward passwords/session parameters through an HTTP redirect.
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        answer(challenge, completionHandler: completionHandler)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // AsyncBytes may deliver server-trust challenges at task scope on supported macOS versions.
        answer(challenge, completionHandler: completionHandler)
    }
    private func answer(_ challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if allowsUntrustedCertificate, challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else { completionHandler(.performDefaultHandling, nil) }
    }
}

nonisolated struct XenSessionIdentity: Equatable, Sendable {
    let generation: UUID
    let poolUUID: String
}

actor XenClient {
    private let transport: any XenTransport
    private var endpoint: URL
    private var session: String?
    private var identity: XenSessionIdentity?
    private var generation = UUID()
    private var reservations: Set<String> = []

    init(endpoint: URL, transport: any XenTransport) { self.endpoint = endpoint; self.transport = transport }

    func connect(username: String, password: String) async throws -> XenSessionIdentity {
        let token = UUID()
        generation = token
        session = nil
        identity = nil
        var redirected = false
        while true {
            do {
                var parameters: [XenValue] = [.string(username), .string(password), .string("1.3"), .string("inchspace")]
                var value: XenValue
                while true {
                    do { value = try await raw("session.login_with_password", parameters); break }
                    catch XenError.api(let code, _) where code == "MESSAGE_PARAMETER_COUNT_MISMATCH" && parameters.count > 2 {
                        parameters.removeLast()
                    }
                }
                let sessionID = value.string
                guard sessionID.hasPrefix("OpaqueRef:"), sessionID != "OpaqueRef:NULL" else { throw XenError.invalid("服务器未返回有效会话。") }
                guard generation == token else { throw CancellationError() }
                session = sessionID
                let pools = try await call("pool.get_all_records").dictionary
                guard generation == token, pools.count == 1, let pool = pools.values.first,
                      !pool.dictionary["uuid", default: .null].string.isEmpty else {
                    throw XenError.invalid("无法确定当前资源池身份。")
                }
                let connected = XenSessionIdentity(generation: token, poolUUID: pool.dictionary["uuid"]!.string)
                identity = connected
                return connected
            } catch XenError.api(let code, let details) where code == "HOST_IS_SLAVE" && !redirected {
                guard let host = details.first, !host.isEmpty, let next = redirectedEndpoint(host) else {
                    throw XenError.invalid("服务器返回的主节点地址无效。")
                }
                endpoint = next
                redirected = true
            } catch {
                if generation == token { session = nil; identity = nil }
                throw error
            }
        }
    }
    private func redirectedEndpoint(_ host: String) -> URL? {
        // XAPI HOST_IS_SLAVE carries a host, never an arbitrary URL, path or credentials.
        guard !host.contains("/"), !host.contains("@"), !host.contains("?"), !host.contains("#"),
              !host.contains(where: \.isWhitespace) else { return nil }
        var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        parts?.host = host
        return parts?.url
    }
    func disconnect() async {
        let previous = session
        session = nil
        identity = nil
        generation = UUID()
        if let previous { _ = try? await raw("session.logout", [.string(previous)]) }
    }
    func currentIdentity() -> XenSessionIdentity? { identity }
    func authenticatedEndpoint() throws -> (URL, String) {
        guard let session, identity != nil else { throw XenError.invalid("集群尚未连接。") }
        return (endpoint, session)
    }
    private func raw(_ method: String, _ parameters: [XenValue]) async throws -> XenValue {
        try XenXMLRPC.result(await transport.send(to: endpoint, body: XenXMLRPC.request(method: method, parameters: parameters)))
    }
    func call(_ method: String, _ arguments: [XenValue] = []) async throws -> XenValue {
        guard let session else { throw XenError.invalid("集群尚未连接。") }
        let token = generation
        let result = try await raw(method, [.string(session)] + arguments)
        guard generation == token else { throw CancellationError() }
        return result
    }
    func records(_ kind: XenResourceKind) async throws -> [XenRecord] {
        let value = try await call("\(kind.api).get_all_records")
        guard case .dictionary(let entries) = value else { throw XenError.invalid("资源清单格式无效。") }
        return entries.map { XenRecord(id: $0.key, kind: kind, fields: $0.value.dictionary) }.filter { record in
            guard kind.api == "VM" else { return true }
            switch kind {
            case .vm: return record.isVM
            case .template: return record["is_a_template"].boolean && !record["is_a_snapshot"].boolean
            case .snapshot: return record["is_a_snapshot"].boolean
            default: return true
            }
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func record(_ kind: XenResourceKind, ref: String) async throws -> XenRecord {
        let value = try await call("\(kind.api).get_record", [.string(ref)])
        guard case .dictionary(let fields) = value, !fields["uuid", default: .null].string.isEmpty else { throw XenError.invalid("资源记录缺少身份信息。") }
        return XenRecord(id: ref, kind: kind, fields: fields)
    }
    func requireIdentity(_ expected: XenSessionIdentity) throws {
        guard identity == expected else { throw XenError.unknown("资源池或连接已变化，请重新连接并确认服务器上的实际结果。") }
    }
    func power(_ action: XenPowerAction, vm: XenRecord, identity expected: XenSessionIdentity) async throws {
        try await mutate(vm, identity: expected, operation: action.operation, validate: { action.available(for: $0) }) { before in
            let args: [XenValue] = [.string(before.id)] + ([.start, .resume].contains(action) ? [.bool(false), .bool(false)] : [])
            let task = try await self.submit("Async.VM.\(action.operation)", args)
            _ = try await self.waitForTask(task, identity: expected)
            let after = try await self.record(.vm, ref: before.id)
            guard after.uuid == before.uuid, after.state == action.targetState else { throw XenError.unknown("任务已返回，但 VM 状态尚未确认。请刷新后核对。") }
        }
    }
    func mutate(_ target: XenRecord, identity expected: XenSessionIdentity, operation: String, validate: (XenRecord) -> Bool,
                        perform: (XenRecord) async throws -> Void) async throws {
        try requireIdentity(expected)
        let key = "\(target.kind.api):\(target.uuid)"
        guard !target.uuid.isEmpty, reservations.insert(key).inserted else { throw XenError.invalid("该资源已有操作正在执行。") }
        defer { reservations.remove(key) }
        let before = try await record(target.kind, ref: target.id)
        try requireIdentity(expected)
        guard before.uuid == target.uuid, validate(before) else { throw XenError.invalid("资源已变化，或服务器当前不允许此操作，请刷新后重试。") }
        try await perform(before)
        try requireIdentity(expected)
    }
    /// A lost acknowledgement must not be treated as a rejected write or retried automatically.
    func submit(_ method: String, _ arguments: [XenValue]) async throws -> XenValue {
        do { return try await call(method, arguments) }
        catch let error as XenError {
            if case .api = error { throw error }
            throw XenError.unknown("请求已提交，但无法确认服务器是否执行。请先核对实际结果，勿重复提交。")
        } catch { throw XenError.unknown("请求结果未知，请核对服务器状态后再操作。") }
    }
    func waitForTask(_ value: XenValue, identity expected: XenSessionIdentity, timeout: TimeInterval = 300) async throws -> XenValue {
        let ref = value.string
        guard ref.hasPrefix("OpaqueRef:"), ref != "OpaqueRef:NULL" else { throw XenError.unknown("服务器未返回有效任务引用，请核对实际结果。") }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            do {
                try Task.checkCancellation()
                try requireIdentity(expected)
                let task = try await call("task.get_record", [.string(ref)]).dictionary
                switch task["status"]?.string {
                case "success": return task["result"] ?? .null
                case "failure", "cancelled": throw XenError.api("TASK_FAILED", task["error_info"]?.array.map(\.string) ?? ["任务已取消"])
                case "pending", "cancelling": break
                default: throw XenError.unknown("任务状态无法识别，请在服务器上核对。")
                }
                try await Task.sleep(for: .seconds(1))
            } catch let error as XenError {
                if case .api = error { throw error }
                throw XenError.unknown("任务 \(ref) 的结果暂时未知，请核对服务器状态。")
            } catch { throw XenError.unknown("任务观察已中断，服务器任务可能仍在执行。") }
        }
        throw XenError.unknown("等待任务超时，服务器任务可能仍在执行。")
    }
    func updateMetadata(_ target: XenRecord, name: String, description: String, identity expected: XenSessionIdentity) async throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw XenError.invalid("名称不能为空。") }
        try await mutate(target, identity: expected, operation: "metadata", validate: { !$0["locked"].boolean }) { before in
            if before.name != name { _ = try await self.submit("\(target.kind.api).set_name_label", [.string(target.id), .string(name)]) }
            if before["name_description"].string != description { _ = try await self.submit("\(target.kind.api).set_name_description", [.string(target.id), .string(description)]) }
            let after = try await self.record(target.kind, ref: target.id)
            guard after.uuid == target.uuid, after.name == name, after["name_description"].string == description else {
                throw XenError.unknown("名称或简介可能仅部分保存，请刷新核对。")
            }
        }
    }
    func snapshot(_ vm: XenRecord, name: String, identity expected: XenSessionIdentity) async throws {
        try await mutate(vm, identity: expected, operation: "snapshot", validate: { $0.isVM && $0.permits("snapshot") }) { before in
            let task = try await self.submit("Async.VM.snapshot", [.string(before.id), .string(name)])
            let result = try await self.waitForTask(task, identity: expected)
            let ref = try XenTaskResult.reference(result)
            let snapshot = try await self.record(.snapshot, ref: ref)
            guard snapshot["is_a_snapshot"].boolean, snapshot["snapshot_of"].string == before.id else { throw XenError.unknown("快照已创建，但归属尚未确认。") }
        }
    }
    func deleteVM(_ vm: XenRecord, identity expected: XenSessionIdentity) async throws {
        try await mutate(vm, identity: expected, operation: "destroy", validate: { $0.isVM && $0.state == "Halted" && $0.permits("destroy") }) { before in
            _ = try await self.submit("VM.destroy", [.string(before.id)])
            do {
                _ = try await self.record(.vm, ref: before.id)
                throw XenError.unknown("删除请求返回后仍能读取 VM，请刷新核对。")
            } catch XenError.api(let code, _) where code == "HANDLE_INVALID" { return }
        }
    }
    func executeProtected(_ capability: XenProtectedCapability) throws { try capability.requireAvailable() }
}
