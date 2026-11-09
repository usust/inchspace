import Foundation
import Combine

struct XenConnectionState {
    var connected = false
    var connecting = false
    var poolUUID: String?
    var updatedAt: Date?
    var records: [XenResourceKind: [XenRecord]] = [:]
    var errors: [XenResourceKind: String] = [:]
    var loading: Set<XenResourceKind> = []
    var connectionError: String?
}

struct XenActivity: Identifiable {
    let id = UUID()
    let clusterID: UUID
    let title: String
    let startedAt = Date()
    var finished = false
    var message: String?
    var unknown = false
}

@MainActor
final class XenStore: ObservableObject {
    @Published private(set) var clusters: [XenCluster] = []
    @Published private(set) var states: [UUID: XenConnectionState] = [:]
    @Published private(set) var activities: [XenActivity] = []
    @Published var error: String?
    private let persistence: XenPersistence
    private let credentials: any XenCredentialStorage
    private let observesEvents: Bool
    private var eventTasks: [UUID: Task<Void, Never>] = [:]
    private let transportFactory: (XenCluster) -> any XenTransport
    let metricHistory: XenMetricHistory
    let alerts: XenAlertCenter
    let transferJournalURL: URL
    private var monitoringTasks: [UUID: Task<Void, Never>] = [:]
    private var alertSubscription: AnyCancellable?
    @Published var transferProgress: [UUID: Double] = [:]
    var fileTransfers: [UUID: XenFileTransfer] = [:]
    var transferTaskRefs: [UUID: String] = [:]
    private var consoleWindows: [UUID: (UUID, XenConsoleWindow)] = [:]
    private var clients: [UUID: XenClient] = [:]
    private var identities: [UUID: XenSessionIdentity] = [:]
    private var epochs: [UUID: UUID] = [:]
    private var recoveryTasks: [UUID: Task<Void, Never>] = [:]
    private var recoveryAttempts: [UUID: Int] = [:]
    private var restored = false
    private var revisions: [String: UUID] = [:]
    private var activeResources: Set<String> = []

    init(persistence: XenPersistence = XenPersistence(), credentials: any XenCredentialStorage = XenKeychain(), alerts: XenAlertCenter? = nil, observesEvents: Bool = true, transportFactory: @escaping (XenCluster) -> any XenTransport = { XenURLTransport(allowsUntrustedCertificate: $0.allowsUntrustedCertificate) }) {
        self.persistence = persistence
        self.metricHistory = XenMetricHistory(root: persistence.url.deletingLastPathComponent().appendingPathComponent("xen-metrics"))
        self.transferJournalURL = persistence.url.deletingLastPathComponent().appendingPathComponent("xen-transfers.json")
        self.alerts = alerts ?? XenAlertCenter()
        self.credentials = credentials
        self.transportFactory = transportFactory
        self.observesEvents = observesEvents
        do { clusters = try persistence.load() }
        catch { self.error = "无法读取 Xen 集群配置：\(error.localizedDescription)" }
        alertSubscription = self.alerts.$rules.dropFirst().sink { [weak self] _ in
            Task { @MainActor in self?.configureMonitoring() }
        }
    }
    private func observeEvents(_ id: UUID) {
        guard observesEvents, let client = clients[id], let identity = identities[id] else { return }
        eventTasks.removeValue(forKey: id)?.cancel()
        eventTasks[id] = Task { [weak self] in
            var token = ""
            var fallback = false
            while !Task.isCancelled {
                guard let self, self.identities[id] == identity else { return }
                do {
                    if fallback {
                        try await Task.sleep(for: .seconds(15))
                        await self.refresh(id, kind: .vm)
                    } else {
                        let result = try await client.call("event.from", [.array([.string("VM")]), .string(token), .double(25)]).dictionary
                        try await client.requireIdentity(identity)
                        guard let next = result["token"]?.string, !next.isEmpty else { fallback = true; continue }
                        token = next
                        if !(result["events"]?.array.isEmpty ?? true) {
                            await self.refresh(id, kind: .vm)
                            for kind: XenResourceKind in [.template, .snapshot] where self.state(id).records[kind] != nil { await self.refresh(id, kind: kind) }
                        }
                    }
                } catch {
                    if Task.isCancelled { return }
                    fallback = true
                    // A read can be retried; no event path ever replays a mutation.
                    await self.refresh(id, kind: .pool)
                }
            }
        }
    }
    func configureMonitoring() {
        for task in monitoringTasks.values { task.cancel() }
        monitoringTasks = [:]
        guard alerts.rules.contains(where: \.enabled) else { return }
        for cluster in clusters where state(cluster.id).connected {
            monitoringTasks[cluster.id] = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.collectAlerts(cluster)
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                }
            }
        }
    }
    private func collectAlerts(_ cluster: XenCluster) async {
        guard let client = clients[cluster.id], let identity = identities[cluster.id] else { return }
        for host in state(cluster.id).records[.host] ?? [] {
            guard !Task.isCancelled else { return }
            do {
                let endpoint = try await client.monitoringEndpoint(host, identity: identity)
                let data = try await XenURLTransport(allowsUntrustedCertificate: cluster.allowsUntrustedCertificate).get(endpoint)
                try await client.requireIdentity(identity)
                let samples = try XenRRD.decode(data)
                guard !Task.isCancelled, identities[cluster.id] == identity else { return }
                alerts.observe(clusterID: cluster.id, poolUUID: identity.poolUUID, samples: samples)
                _ = try await metricHistory.merge(samples, clusterID: cluster.id, poolUUID: identity.poolUUID)
            } catch { /* Missing samples never imply recovery. The resource page shows connection errors. */ }
        }
    }
    func connectionIdentity(_ id: UUID) -> XenSessionIdentity? { identities[id] }
    func connectionClient(_ id: UUID) -> XenClient? { clients[id] }
    func appendRecoveredActivity(_ id: UUID, title: String) {
        var activity = XenActivity(clusterID: id, title: title)
        activity.finished = true; activity.unknown = true; activity.message = "请核对原任务与本地文件，不会自动重放传输。"
        activities.insert(activity, at: 0)
    }
    func cancelTransfer(_ id: UUID) {
        fileTransfers[id]?.cancel()
        if let ref = transferTaskRefs[id], let client = clients[id] {
            Task { _ = try? await client.submit("task.cancel", [.string(ref)]) }
        }
        if let index = activities.firstIndex(where: { $0.clusterID == id && !$0.finished }) {
            activities[index].message = "已请求取消，正在核对服务器任务。"
        }
    }
    func openConsole(_ id: UUID, vm: XenRecord) async {
        guard let client = clients[id], let identity = identities[id], let cluster = clusters.first(where: { $0.id == id }) else { error = "请先连接集群。"; return }
        do {
            let (url, session) = try await client.consoleLocation(vm, identity: identity)
            guard identities[id] == identity else { return }
            let token = UUID()
            let window = XenConsoleWindow(name: vm.name)
            window.closed = { [weak self] in self?.consoleWindows[token] = nil }
            consoleWindows[token] = (id, window)
            window.open(location: url, session: session, allowUntrusted: cluster.allowsUntrustedCertificate)
        } catch { self.error = error.localizedDescription }
    }
    func restoreConnections() async {
        guard !restored else { return }
        restored = true
        for cluster in clusters where cluster.connectsOnLaunch { await connect(cluster) }
    }
    private func scheduleRecovery(_ id: UUID) {
        guard let cluster = clusters.first(where: { $0.id == id }), cluster.reconnectsAutomatically,
              recoveryTasks[id] == nil, !hasActiveOperation(id), (recoveryAttempts[id] ?? 0) < 3 else { return }
        let attempt = (recoveryAttempts[id] ?? 0) + 1
        recoveryAttempts[id] = attempt
        recoveryTasks[id] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(Double(1 << attempt))) } catch { return }
            guard let self else { return }
            self.recoveryTasks[id] = nil
            guard !self.state(id).connected, !self.state(id).connecting else { return }
            await self.connect(cluster)
        }
    }
    func state(_ id: UUID) -> XenConnectionState { states[id] ?? XenConnectionState() }
    func save(_ cluster: XenCluster, password: String?) throws {
        _ = try cluster.endpoint()
        guard !cluster.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !cluster.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw XenError.invalid("请填写集群名称和用户名。") }
        guard !state(cluster.id).connected, !state(cluster.id).connecting else { throw XenError.invalid("请先断开连接再编辑配置。") }
        var updated = clusters
        let existing = updated.firstIndex { $0.id == cluster.id }
        var previousPassword: String?
        if password != nil && existing != nil {
            do { previousPassword = try credentials.password(for: cluster.id) }
            catch XenError.missingCredential { previousPassword = nil }
        }
        if let password { try credentials.save(password, for: cluster.id) }
        else if existing == nil { throw XenError.invalid("请填写密码。") }
        if let existing { updated[existing] = cluster } else { updated.append(cluster) }
        do { try persistence.save(updated) }
        catch {
            if password != nil {
                if let previousPassword { try? credentials.save(previousPassword, for: cluster.id) }
                else { try? credentials.delete(for: cluster.id) }
            }
            throw error
        }
        clusters = updated
    }
    func remove(_ id: UUID) async {
        guard !hasActiveOperation(id), !state(id).connecting else { error = "请等待当前连接或任务结束。"; return }
        let remaining = clusters.filter { $0.id != id }
        do {
            try persistence.save(remaining)
            do { try credentials.delete(for: id) }
            catch { try? persistence.save(clusters); throw error }
            await disconnect(id)
            clusters = remaining
            states[id] = nil
        } catch { self.error = error.localizedDescription }
    }
    func connect(_ requestedCluster: XenCluster, password: String? = nil) async {
        let cluster = clusters.first { $0.id == requestedCluster.id } ?? requestedCluster
        guard !state(cluster.id).connecting, !state(cluster.id).connected else { return }
        let epoch = UUID()
        epochs[cluster.id] = epoch
        states[cluster.id, default: XenConnectionState()].connecting = true
        states[cluster.id]?.connectionError = nil
        do {
            if let previous = clients.removeValue(forKey: cluster.id) { Task { await previous.disconnect() } }
            guard epochs[cluster.id] == epoch else { return }
            let secret = try password ?? credentials.password(for: cluster.id)
            let client = XenClient(endpoint: try cluster.endpoint(), transport: transportFactory(cluster))
            clients[cluster.id] = client
            let identity = try await client.connect(username: cluster.username, password: secret)
            guard epochs[cluster.id] == epoch else { await client.disconnect(); return }
            if state(cluster.id).poolUUID != identity.poolUUID { states[cluster.id]?.records = [:]; states[cluster.id]?.errors = [:] }
            identities[cluster.id] = identity
            states[cluster.id]?.poolUUID = identity.poolUUID
            states[cluster.id]?.connected = true
            states[cluster.id]?.connecting = false
            for kind: XenResourceKind in [.pool, .host, .vm, .storage, .network] { await refresh(cluster.id, kind: kind) }
            await reconcileTransfers(cluster.id)
            configureMonitoring()
            observeEvents(cluster.id)
        } catch {
            guard epochs[cluster.id] == epoch else { return }
            if let client = clients.removeValue(forKey: cluster.id) { await client.disconnect() }
            guard epochs[cluster.id] == epoch else { return }
            identities[cluster.id] = nil
            states[cluster.id]?.connecting = false
            states[cluster.id]?.connected = false
            states[cluster.id]?.connectionError = error.localizedDescription
            scheduleRecovery(cluster.id)
        }
    }
    func disconnect(_ id: UUID) async {
        guard !hasActiveOperation(id) else { error = "请先等待当前任务结束。"; return }
        recoveryTasks.removeValue(forKey: id)?.cancel()
        recoveryAttempts[id] = 0
        monitoringTasks.removeValue(forKey: id)?.cancel()
        eventTasks.removeValue(forKey: id)?.cancel()
        let windows = consoleWindows.values.filter { $0.0 == id }.map { $0.1 }
        for window in windows { window.close() }
        epochs[id] = UUID()
        identities[id] = nil
        states[id]?.connected = false
        states[id]?.connecting = false
        states[id]?.loading = []
        if let client = clients.removeValue(forKey: id) { await client.disconnect() }
    }
    func refresh(_ id: UUID, kind: XenResourceKind) async {
        guard let client = clients[id], let identity = identities[id] else { return }
        let key = "\(id):\(kind.rawValue)"
        let revision = UUID()
        revisions[key] = revision
        states[id, default: XenConnectionState()].loading.insert(kind)
        defer { if revisions[key] == revision { states[id]?.loading.remove(kind) } }
        do {
            let records = try await client.records(kind)
            guard identities[id] == identity, revisions[key] == revision else { return }
            states[id]?.records[kind] = records
            states[id]?.errors[kind] = nil
            states[id]?.updatedAt = Date()
            if kind == .pool { recoveryAttempts[id] = 0 }
        } catch {
            guard identities[id] == identity, revisions[key] == revision else { return }
            states[id]?.errors[kind] = error.localizedDescription
            let sessionInvalid: Bool
            if case XenError.api(let code, _) = error { sessionInvalid = code == "SESSION_INVALID" }
            else { sessionInvalid = (error as? XenError).map { if case .transport = $0 { true } else { false } } ?? false }
            if sessionInvalid {
                states[id]?.connected = false
                states[id]?.connectionError = "连接已中断，请重新连接。"
                identities[id] = nil
                eventTasks.removeValue(forKey: id)?.cancel()
                let windows = consoleWindows.values.filter { $0.0 == id }.map { $0.1 }
                for window in windows { window.close() }
                monitoringTasks.removeValue(forKey: id)?.cancel()
                scheduleRecovery(id)
            }
        }
    }
    func relatedRecords(_ id: UUID, api: String) async throws -> [String: XenValue] {
        guard let client = clients[id], let identity = identities[id] else { throw XenError.invalid("请先连接集群。") }
        let value = try await client.call("\(api).get_all_records")
        guard identities[id] == identity else { throw CancellationError() }
        return value.dictionary
    }
    func hasActiveOperation(_ id: UUID) -> Bool { activities.contains { $0.clusterID == id && !$0.finished } }
    func isBusy(_ record: XenRecord, cluster id: UUID) -> Bool {
        let pool = state(id).poolUUID ?? id.uuidString
        return activeResources.contains("\(pool):\(record.kind.api):\(record.uuid)")
    }
    func perform(_ id: UUID, title: String, record: XenRecord, action: @escaping (XenClient, XenSessionIdentity) async throws -> Void) async {
        guard let client = clients[id], let identity = identities[id] else { error = "请先连接集群。"; return }
        let key = "\(identity.poolUUID):\(record.kind.api):\(record.uuid)"
        guard activeResources.insert(key).inserted else { error = "该资源已有操作正在执行。"; return }
        defer { activeResources.remove(key) }
        let activity = XenActivity(clusterID: id, title: "\(title) · \(record.name)")
        activities.insert(activity, at: 0)
        // Bound finished history while retaining every active task.
        if activities.count > 100 { activities = activities.filter { !$0.finished } + Array(activities.filter(\.finished).prefix(80)) }
        do {
            try await action(client, identity)
            if let index = activities.firstIndex(where: { $0.id == activity.id }) { activities[index].finished = true; activities[index].message = "已完成" }
        } catch {
            if let index = activities.firstIndex(where: { $0.id == activity.id }) {
                activities[index].finished = true
                activities[index].message = error.localizedDescription
                activities[index].unknown = (error as? XenError)?.outcomeUnknown == true
            }
            self.error = error.localizedDescription
        }
        await refresh(id, kind: record.kind)
    }
    func power(_ id: UUID, record: XenRecord, action: XenPowerAction) async {
        await perform(id, title: action.title, record: record) { client, identity in try await client.power(action, vm: record, identity: identity) }
    }
}
