import AppKit
import Combine
import Foundation
import ServiceManagement

@MainActor
final class RunnerStore: ObservableObject {
    @Published private(set) var tasks: [RunnerTask] = []
    @Published private(set) var snapshots: [UUID: RunnerTaskSnapshot] = [:]
    @Published private(set) var localServices: [RunnerService] = []
    @Published private(set) var discoverableLocalServices: [RunnerService] = []
    @Published private(set) var managedLocalServices: [RunnerManagedService] = []
    @Published private(set) var remoteServices: [UUID: [RunnerService]] = [:]
    @Published private(set) var servers: [RunnerServer] = []
    @Published private(set) var discoveries: [RunnerDiscovery] = []
    @Published private(set) var isDiscovering = false
    @Published private(set) var busyServiceIDs: Set<String> = []
    @Published var presentedError: RunnerPresentedError?

    private let persistence: RunnerPersistence
    private let localServiceManager = LocalRunnerServiceManager()
    private var processes: [UUID: ManagedRunnerProcess] = [:]
    private var metricsTask: Task<Void, Never>?
    private var hasBootstrapped = false

    init(persistence: RunnerPersistence = RunnerPersistence()) {
        self.persistence = persistence
        do {
            let library = try persistence.load()
            tasks = library.tasks
            servers = library.servers
            managedLocalServices = library.managedServices
            snapshots = Dictionary(uniqueKeysWithValues: library.tasks.map { ($0.id, RunnerTaskSnapshot(id: $0.id)) })
        } catch {
            presentedError = RunnerPresentedError(error)
        }
    }

    deinit { metricsTask?.cancel() }

    var runningCount: Int {
        snapshots.values.filter { $0.state == .running || $0.state == .paused || $0.state == .starting }.count
    }

    var cpuPercent: Double { snapshots.values.reduce(0) { $0 + $1.cpuPercent } }
    var memoryBytes: UInt64 { snapshots.values.reduce(0) { $0 + $1.memoryBytes } }
    var memoryPercent: Double {
        guard ProcessInfo.processInfo.physicalMemory > 0 else { return 0 }
        return Double(memoryBytes) / Double(ProcessInfo.processInfo.physicalMemory) * 100
    }

    func bootstrap() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        startMetricsUpdates()
        await refreshLocalServices()
        await discover()
        for task in tasks where task.launchMode == .login {
            start(task.id)
        }
    }

    func add(_ task: RunnerTask) {
        tasks.append(task)
        snapshots[task.id] = RunnerTaskSnapshot(id: task.id)
        save()
        if task.launchMode == .login { enableLoginItem() }
    }

    func update(_ task: RunnerTask) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[index] = task
        save()
        if task.launchMode == .login { enableLoginItem() }
    }

    func delete(_ id: UUID) {
        guard snapshots[id]?.state != .running, snapshots[id]?.state != .paused else {
            present(RunnerError.processFailed("请先停止任务，再将它删除。"))
            return
        }
        tasks.removeAll { $0.id == id }
        snapshots[id] = nil
        save()
    }

    func toggleFavorite(_ id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].isFavorite.toggle()
        save()
    }

    func start(_ id: UUID) {
        guard processes[id] == nil, let task = tasks.first(where: { $0.id == id }) else { return }
        guard !task.name.trimmingCharacters(in: .whitespaces).isEmpty,
              !task.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            present(RunnerError.invalidTask)
            return
        }

        snapshots[id, default: RunnerTaskSnapshot(id: id)].state = .starting
        appendLog(id, "正在启动“\(task.name)”…", isError: false)

        do {
            let directoryURL = try resolvedDirectory(for: task)
            let hasAccess = directoryURL.startAccessingSecurityScopedResource()
            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-l", "-c", task.command]
            process.currentDirectoryURL = directoryURL
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = environment["PATH"].flatMap { $0.isEmpty ? nil : $0 }
                ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            task.environment.forEach { variable in
                if !variable.key.isEmpty { environment[variable.key] = variable.value }
            }
            process.environment = environment
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            let managed = ManagedRunnerProcess(
                process: process,
                outputPipe: outputPipe,
                errorPipe: errorPipe,
                securityScopedURL: hasAccess ? directoryURL : nil
            )
            processes[id] = managed
            outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                let text = String(decoding: data, as: UTF8.self)
                Task { @MainActor [weak self] in self?.appendOutput(id, text, isError: false) }
            }
            errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                let text = String(decoding: data, as: UTF8.self)
                Task { @MainActor [weak self] in self?.appendOutput(id, text, isError: true) }
            }
            process.terminationHandler = { [weak self] process in
                Task { @MainActor [weak self] in self?.processDidExit(id, code: process.terminationStatus) }
            }
            try process.run()
            snapshots[id]?.state = .running
            snapshots[id]?.pid = process.processIdentifier
            snapshots[id]?.startedAt = Date()
            snapshots[id]?.lastExitCode = nil
            appendLog(id, "任务已开始运行。", isError: false)
        } catch {
            processes[id]?.finishAccess()
            processes[id] = nil
            snapshots[id]?.state = .failed
            appendLog(id, error.localizedDescription, isError: true)
            present(error)
        }
    }

    func stop(_ id: UUID) {
        guard let managed = processes[id] else { return }
        appendLog(id, "正在停止任务…", isError: false)
        managed.process.terminate()
    }

    func restart(_ id: UUID) {
        guard let managed = processes[id] else {
            start(id)
            return
        }
        managed.restartWhenFinished = true
        managed.process.terminate()
    }

    func togglePause(_ id: UUID) {
        guard let managed = processes[id] else { return }
        if snapshots[id]?.state == .paused {
            if managed.process.resume() {
                snapshots[id]?.state = .running
                appendLog(id, "任务已继续。", isError: false)
            }
        } else if managed.process.suspend() {
            snapshots[id]?.state = .paused
            appendLog(id, "任务已暂停。", isError: false)
        }
    }

    func clearLogs(_ id: UUID) { snapshots[id]?.logs.removeAll() }

    func refreshLocalServices() async {
        do {
            let result = try await localServiceManager.services(including: managedLocalServices)
            localServices = result.0
            discoverableLocalServices = result.1
        }
        catch { present(error) }
    }

    func addManagedService(_ service: RunnerManagedService) {
        guard !managedLocalServices.contains(where: { $0.id == service.id }) else { return }
        managedLocalServices.append(service)
        save()
        Task { await refreshLocalServices() }
    }

    func removeManagedService(_ service: RunnerService) {
        managedLocalServices.removeAll {
            $0.identifier == service.identifier && $0.kind == service.kind && $0.isSystemService == service.isSystemService
        }
        save()
        Task { await refreshLocalServices() }
    }

    func isManaged(_ service: RunnerService) -> Bool {
        managedLocalServices.contains {
            $0.identifier == service.identifier && $0.kind == service.kind && $0.isSystemService == service.isSystemService
        }
    }

    func operateLocalService(_ service: RunnerService, action: RunnerServiceAction) async {
        busyServiceIDs.insert(service.id)
        defer { busyServiceIDs.remove(service.id) }
        do {
            switch action {
            case .start: try await localServiceManager.start(service)
            case .stop: try await localServiceManager.stop(service)
            case .restart: try await localServiceManager.restart(service)
            }
            await refreshLocalServices()
        } catch { present(error) }
    }

    func localServiceLogs(_ service: RunnerService) async -> String {
        do { return try await localServiceManager.logs(for: service) }
        catch { present(error); return error.localizedDescription }
    }

    func addServer(_ server: RunnerServer) {
        servers.append(server)
        save()
    }

    func deleteServer(_ id: UUID) {
        RunnerServerCredentialStore.deletePassword(for: id)
        servers.removeAll { $0.id == id }
        remoteServices[id] = nil
        save()
    }

    func refreshServer(_ server: RunnerServer) async {
        do { remoteServices[server.id] = try await SystemdRunnerServiceManager(server: server).services() }
        catch { present(error) }
    }

    func operateRemoteService(_ service: RunnerService, on server: RunnerServer, action: RunnerServiceAction) async {
        let busyID = "\(server.id):\(service.id)"
        busyServiceIDs.insert(busyID)
        defer { busyServiceIDs.remove(busyID) }
        do {
            let manager = SystemdRunnerServiceManager(server: server)
            switch action {
            case .start: try await manager.start(service)
            case .stop: try await manager.stop(service)
            case .restart: try await manager.restart(service)
            }
            await refreshServer(server)
        } catch { present(error) }
    }

    func remoteServiceLogs(_ service: RunnerService, on server: RunnerServer) async -> String {
        do { return try await SystemdRunnerServiceManager(server: server).logs(for: service) }
        catch { present(error); return error.localizedDescription }
    }

    func discover() async {
        guard !isDiscovering else { return }
        isDiscovering = true
        defer { isDiscovering = false }
        var found: [RunnerDiscovery] = []
        do {
            let services = try await localServiceManager.services()
            found += services.prefix(12).map {
                RunnerDiscovery(id: $0.id, name: $0.displayName, detail: $0.state.title, symbol: "server.rack", kind: .service)
            }
        } catch { /* Discovery remains best effort. */ }

        if let ports = try? await RunnerCommandExecutor.run(
            executable: "/usr/sbin/lsof",
            arguments: ["-nP", "-iTCP", "-sTCP:LISTEN"]
        ) {
            let rows = ports.output.split(separator: "\n").dropFirst()
            var seen = Set<String>()
            for row in rows {
                let columns = row.split(whereSeparator: \Character.isWhitespace)
                guard columns.count >= 9 else { continue }
                let processName = String(columns[0])
                let endpoint = String(columns.last ?? "")
                let port = endpoint.split(separator: ":").last.map(String.init) ?? endpoint
                let key = "port:\(port)"
                guard seen.insert(key).inserted else { continue }
                found.append(RunnerDiscovery(id: key, name: processName, detail: "正在使用端口 \(port)", symbol: "network", kind: .port))
            }
        }
        discoveries = found
    }

    private func resolvedDirectory(for task: RunnerTask) throws -> URL {
        if let bookmark = task.workingDirectoryBookmark {
            do { return try SecurityScopedBookmarkService.resolve(bookmark) }
            catch { throw RunnerError.accessExpired }
        }
        let path = NSString(string: task.workingDirectoryPath).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw RunnerError.processFailed("工作目录不存在，请编辑任务并重新选择。")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func appendOutput(_ id: UUID, _ output: String, isError: Bool) {
        for line in output.split(whereSeparator: \Character.isNewline) where !line.isEmpty {
            appendLog(id, String(line), isError: isError)
        }
    }

    private func appendLog(_ id: UUID, _ message: String, isError: Bool) {
        snapshots[id, default: RunnerTaskSnapshot(id: id)].logs.append(
            RunnerLogEntry(timestamp: Date(), message: message, isError: isError)
        )
        if let count = snapshots[id]?.logs.count, count > 4_000 {
            snapshots[id]?.logs.removeFirst(count - 4_000)
        }
    }

    private func processDidExit(_ id: UUID, code: Int32) {
        guard let managed = processes.removeValue(forKey: id) else { return }
        managed.outputPipe.fileHandleForReading.readabilityHandler = nil
        managed.errorPipe.fileHandleForReading.readabilityHandler = nil
        managed.finishAccess()
        snapshots[id]?.pid = nil
        snapshots[id]?.cpuPercent = 0
        snapshots[id]?.memoryBytes = 0
        snapshots[id]?.lastExitCode = code
        snapshots[id]?.state = code == 0 ? .stopped : .failed
        appendLog(id, code == 0 ? "任务已停止。" : "任务异常结束（代码 \(code)）。", isError: code != 0)
        if managed.restartWhenFinished {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                self?.start(id)
            }
        }
    }

    private func startMetricsUpdates() {
        metricsTask?.cancel()
        metricsTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshMetrics()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func refreshMetrics() async {
        let ids = processes.mapValues { $0.process.processIdentifier }
        guard !ids.isEmpty else { return }
        let pidList = ids.values.map(String.init).joined(separator: ",")
        guard let result = try? await RunnerCommandExecutor.run(
            executable: "/bin/ps", arguments: ["-o", "pid=,%cpu=,rss=", "-p", pidList]
        ) else { return }
        var metrics: [Int32: (Double, UInt64)] = [:]
        for row in result.output.split(separator: "\n") {
            let columns = row.split(whereSeparator: \Character.isWhitespace)
            guard columns.count >= 3, let pid = Int32(columns[0]), let cpu = Double(columns[1]), let rss = UInt64(columns[2]) else { continue }
            metrics[pid] = (cpu, rss * 1024)
        }
        for (id, pid) in ids {
            snapshots[id]?.cpuPercent = metrics[pid]?.0 ?? 0
            snapshots[id]?.memoryBytes = metrics[pid]?.1 ?? 0
        }
    }

    private func enableLoginItem() {
        do {
            if SMAppService.mainApp.status == .notRegistered { try SMAppService.mainApp.register() }
        } catch {
            present(RunnerError.processFailed("任务已保存，但无法加入登录项：\(error.localizedDescription)"))
        }
    }

    private func save() {
        do { try persistence.save(RunnerLibrary(tasks: tasks, servers: servers, managedServices: managedLocalServices)) }
        catch { present(error) }
    }

    private func present(_ error: Error) { presentedError = RunnerPresentedError(error) }
}

enum RunnerServiceAction: Equatable { case start, stop, restart }

struct RunnerPresentedError: Identifiable {
    let id = UUID()
    let title: String
    let message: String

    init(_ error: Error) {
        title = "无法完成操作"
        message = error.localizedDescription
    }
}

private final class ManagedRunnerProcess: @unchecked Sendable {
    let process: Process
    let outputPipe: Pipe
    let errorPipe: Pipe
    let securityScopedURL: URL?
    var restartWhenFinished = false

    init(process: Process, outputPipe: Pipe, errorPipe: Pipe, securityScopedURL: URL?) {
        self.process = process
        self.outputPipe = outputPipe
        self.errorPipe = errorPipe
        self.securityScopedURL = securityScopedURL
    }

    func finishAccess() { securityScopedURL?.stopAccessingSecurityScopedResource() }
}
