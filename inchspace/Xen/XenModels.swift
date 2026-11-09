import Foundation

/// XML-RPC values remain typed across the transport boundary; no JSON coercion of booleans or 64-bit integers.
nonisolated indirect enum XenValue: Sendable, Equatable {
    case string(String), integer(Int64), double(Double), bool(Bool)
    case array([XenValue]), dictionary([String: XenValue]), null

    var string: String {
        switch self {
        case .string(let value): value
        case .integer(let value): String(value)
        case .double(let value): String(value)
        case .bool(let value): value ? "true" : "false"
        default: ""
        }
    }
    var dictionary: [String: XenValue] { if case .dictionary(let value) = self { value } else { [:] } }
    var array: [XenValue] { if case .array(let value) = self { value } else { [] } }
    var boolean: Bool { self == .bool(true) || string == "true" || string == "1" }
    var number: Double? { Double(string) }
}

nonisolated struct XenCluster: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var address: String
    var username = "root"
    var allowsUntrustedCertificate = false
    var connectsOnLaunch = false
    var reconnectsAutomatically = false

    private enum CodingKeys: String, CodingKey { case id, name, address, username, allowsUntrustedCertificate, connectsOnLaunch, reconnectsAutomatically }
    init(id: UUID = UUID(), name: String, address: String, username: String = "root", allowsUntrustedCertificate: Bool = false, connectsOnLaunch: Bool = false, reconnectsAutomatically: Bool = false) {
        self.id = id; self.name = name; self.address = address; self.username = username
        self.allowsUntrustedCertificate = allowsUntrustedCertificate
        self.connectsOnLaunch = connectsOnLaunch; self.reconnectsAutomatically = reconnectsAutomatically
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        address = try values.decode(String.self, forKey: .address)
        username = try values.decode(String.self, forKey: .username)
        allowsUntrustedCertificate = try values.decodeIfPresent(Bool.self, forKey: .allowsUntrustedCertificate) ?? false
        connectsOnLaunch = try values.decodeIfPresent(Bool.self, forKey: .connectsOnLaunch) ?? false
        reconnectsAutomatically = try values.decodeIfPresent(Bool.self, forKey: .reconnectsAutomatically) ?? false
    }
    func endpoint() throws -> URL {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/",
              url.port.map({ (1...65535).contains($0) }) ?? true else {
            throw XenError.invalid("请输入完整的管理地址，例如 https://192.168.1.10，不包含路径或账号。")
        }
        return url
    }
}

nonisolated enum XenError: LocalizedError, Sendable, Equatable {
    case missingCredential
    case invalid(String), api(String, [String]), transport(String), unknown(String), guarded(String)
    var errorDescription: String? {
        switch self {
        case .missingCredential: "请重新输入集群密码。"
        case .invalid(let message), .transport(let message), .unknown(let message), .guarded(let message): message
        case .api(let code, let details): "\(code)\(details.isEmpty ? "" : "：" + details.joined(separator: " · "))"
        }
    }
    var outcomeUnknown: Bool { if case .unknown = self { true } else { false } }
}

nonisolated enum XenResourceKind: String, CaseIterable, Identifiable, Sendable {
    case pool, host, vm, template, snapshot, storage, network, disk, task, message, patch, subject, role
    var id: String { rawValue }
    var api: String {
        switch self {
        case .pool: "pool"
        case .host: "host"
        case .vm, .template, .snapshot: "VM"
        case .storage: "SR"
        case .network: "network"
        case .disk: "VDI"
        case .task: "task"
        case .message: "message"
        case .patch: "pool_patch"
        case .subject: "subject"
        case .role: "role"
        }
    }
    var title: String {
        switch self {
        case .pool: "概览"
        case .host: "主机"
        case .vm: "虚拟机"
        case .template: "模板"
        case .snapshot: "快照"
        case .storage: "存储"
        case .network: "网络"
        case .disk: "虚拟磁盘"
        case .task: "任务"
        case .message: "消息"
        case .patch: "补丁"
        case .subject: "用户"
        case .role: "角色"
        }
    }
    var symbol: String {
        switch self {
        case .pool: "square.grid.2x2"
        case .host: "server.rack"
        case .vm: "desktopcomputer"
        case .template: "doc.on.doc"
        case .snapshot: "camera"
        case .storage: "externaldrive"
        case .network: "network"
        case .disk: "internaldrive"
        case .task: "list.bullet.rectangle"
        case .message: "bell"
        case .patch: "bandage"
        case .subject: "person.2"
        case .role: "key"
        }
    }
    static let primary: [Self] = [.pool, .host, .vm, .storage, .network]
    static let additional: [Self] = [.template, .snapshot, .disk, .task, .message, .patch, .subject, .role]
}

nonisolated struct XenRecord: Identifiable, Sendable, Equatable {
    let id: String
    let kind: XenResourceKind
    let fields: [String: XenValue]
    subscript(_ key: String) -> XenValue { fields[key] ?? .null }
    var uuid: String { self["uuid"].string }
    var name: String {
        [self["name_label"].string, self["name"].string, self["subject_identifier"].string, uuid, id].first { !$0.isEmpty } ?? id
    }
    var state: String { self["power_state"].string }
    var isVM: Bool { kind == .vm && !self["is_a_template"].boolean && !self["is_a_snapshot"].boolean && !self["is_control_domain"].boolean }
    var stateTitle: String {
        switch state {
        case "Running": "运行中"
        case "Halted": "已关机"
        case "Paused": "已暂停"
        case "Suspended": "已挂起"
        default: self["status"].string.isEmpty ? "—" : self["status"].string
        }
    }
    var allowedOperations: Set<String> { Set(self["allowed_operations"].array.map(\.string)) }
    func permits(_ operation: String) -> Bool {
        allowedOperations.contains(operation) && self["blocked_operations"].dictionary[operation] == nil
            && self["current_operations"].dictionary.isEmpty && !self["locked"].boolean && !self["Locked"].boolean
    }
}

nonisolated enum XenPowerAction: String, CaseIterable, Identifiable, Sendable {
    case start, shutdown, reboot, forceShutdown, pause, unpause, suspend, resume
    var id: String { rawValue }
    var title: String {
        switch self {
        case .start: "启动"
        case .shutdown: "正常关机"
        case .reboot: "重启"
        case .forceShutdown: "强制关机"
        case .pause: "暂停"
        case .unpause: "继续运行"
        case .suspend: "挂起"
        case .resume: "恢复运行"
        }
    }
    var operation: String {
        switch self {
        case .shutdown: "clean_shutdown"
        case .reboot: "clean_reboot"
        case .forceShutdown: "hard_shutdown"
        default: rawValue
        }
    }
    var targetState: String {
        switch self {
        case .shutdown, .forceShutdown: "Halted"
        case .pause: "Paused"
        case .suspend: "Suspended"
        default: "Running"
        }
    }
    func available(for vm: XenRecord) -> Bool {
        guard vm.isVM, !vm.uuid.isEmpty, !vm["locked"].boolean, !vm["Locked"].boolean,
              vm.allowedOperations.contains(operation), vm["blocked_operations"].dictionary[operation] == nil,
              vm["current_operations"].dictionary.isEmpty || self == .forceShutdown else { return false }
        switch self {
        case .start: return vm.state == "Halted"
        case .shutdown, .reboot, .pause, .suspend: return vm.state == "Running"
        case .unpause: return vm.state == "Paused"
        case .resume: return vm.state == "Suspended"
        case .forceShutdown: return ["Running", "Paused", "Suspended"].contains(vm.state)
        }
    }
}

/// The reference application's guarded operations stay closed in the service, not just in the UI.
nonisolated enum XenProtectedCapability: String, CaseIterable, Identifiable, Sendable {
    case migration, copy, storageLifecycle, networkTopology, hostMaintenance, poolGovernance, ha, patches, rbac
    var id: String { rawValue }
    var title: String {
        switch self {
        case .migration: "迁移虚拟机"
        case .copy: "复制虚拟机"
        case .storageLifecycle: "存储仓库生命周期"
        case .networkTopology: "物理接口、VLAN 与 Bond"
        case .hostMaintenance: "主机维护与疏散"
        case .poolGovernance: "资源池治理"
        case .ha: "高可用配置"
        case .patches: "安装补丁"
        case .rbac: "用户与权限变更"
        }
    }
    func requireAvailable() throws {
        throw XenError.guarded("\(title)尚未完成协议、恢复与实机验收，暂不可执行。")
    }
}
