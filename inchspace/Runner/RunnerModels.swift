import Foundation

enum RunnerTaskState: String, Codable, Sendable {
    case stopped
    case starting
    case running
    case paused
    case failed

    var title: String {
        switch self {
        case .stopped: "已停止"
        case .starting: "正在启动"
        case .running: "运行中"
        case .paused: "已暂停"
        case .failed: "异常"
        }
    }
}

enum RunnerLaunchMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case temporary
    case background
    case login

    var id: String { rawValue }

    var title: String {
        switch self {
        case .temporary: "临时运行"
        case .background: "后台运行"
        case .login: "登录自动启动"
        }
    }

    var detail: String {
        switch self {
        case .temporary: "关闭应用时停止"
        case .background: "在本次登录期间持续运行"
        case .login: "登录 Mac 后自动恢复"
        }
    }
}

struct RunnerEnvironmentVariable: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var key = ""
    var value = ""
}

struct RunnerTask: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var command: String
    var workingDirectoryPath: String
    var workingDirectoryBookmark: Data?
    var launchMode: RunnerLaunchMode
    var environment: [RunnerEnvironmentVariable]
    var port: Int? = nil
    var isFavorite = false
    var createdAt = Date()
}

struct RunnerTaskSnapshot: Identifiable, Sendable {
    let id: UUID
    var state: RunnerTaskState = .stopped
    var pid: Int32?
    var cpuPercent: Double = 0
    var memoryBytes: UInt64 = 0
    var startedAt: Date?
    var lastExitCode: Int32?
    var logs: [RunnerLogEntry] = []

    var uptime: TimeInterval {
        startedAt.map { Date().timeIntervalSince($0) } ?? 0
    }
}

struct RunnerLogEntry: Identifiable, Sendable {
    let id = UUID()
    let timestamp: Date
    let message: String
    let isError: Bool
}

enum RunnerServiceKind: String, Codable, Sendable {
    case homebrew
    case launchd
    case systemd

    var title: String {
        switch self {
        case .homebrew: "应用服务"
        case .launchd: "系统服务"
        case .systemd: "服务器服务"
        }
    }
}

enum RunnerServiceState: String, Codable, Sendable {
    case running
    case stopped
    case failed
    case unknown

    var title: String {
        switch self {
        case .running: "运行中"
        case .stopped: "已停止"
        case .failed: "异常"
        case .unknown: "未知"
        }
    }
}

struct RunnerService: Codable, Identifiable, Hashable, Sendable {
    var id: String { "\(kind.rawValue):\(isSystemService ? "system" : "user"):\(identifier)" }
    let identifier: String
    var displayName: String
    let kind: RunnerServiceKind
    var state: RunnerServiceState
    var detail: String?
    var isSystemService = false

    var requiresConfirmation: Bool {
        isSystemService || identifier.hasPrefix("com.apple.")
    }

    /// A service-oriented name for the primary label in the UI. GitHub Actions
    /// launchd labels end in the runner machine name, while the preceding value
    /// identifies the repository/service the runner belongs to.
    var serviceName: String {
        guard kind == .launchd,
              identifier.hasPrefix("actions.runner.") else { return displayName }
        let suffix = identifier.dropFirst("actions.runner.".count)
        guard let separator = suffix.lastIndex(of: ".") else { return displayName }
        let name = suffix[..<separator]
        return name.isEmpty ? displayName : String(name)
    }

    var instanceName: String? {
        guard kind == .launchd,
              identifier.hasPrefix("actions.runner."),
              let name = identifier.split(separator: ".").last.map(String.init),
              name != serviceName else { return nil }
        return name
    }
}

struct RunnerManagedService: Codable, Identifiable, Hashable, Sendable {
    var id: String { "\(kind.rawValue):\(isSystemService ? "system" : "user"):\(identifier)" }
    let identifier: String
    var displayName: String
    let kind: RunnerServiceKind
    var isSystemService = false
}

enum RunnerServerAuthentication: String, Codable, CaseIterable, Identifiable, Sendable {
    case password
    case sshKey

    var id: String { rawValue }

    var title: String {
        switch self {
        case .password: "密码"
        case .sshKey: "SSH Key"
        }
    }
}

enum RunnerServiceIdentifierParser {
    nonisolated static func parse(_ input: String) -> String? {
        let identifier = input
            .split(whereSeparator: \Character.isWhitespace)
            .last.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !identifier.isEmpty, !identifier.contains("/") else { return nil }
        return identifier
    }
}

struct RunnerServer: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var host: String
    var username: String
    var port: Int = 22
    var authentication: RunnerServerAuthentication = .password
    var keyPath: String = ""
    var keyBookmark: Data?

    init(
        id: UUID = UUID(),
        name: String,
        host: String,
        username: String,
        port: Int = 22,
        authentication: RunnerServerAuthentication = .password,
        keyPath: String = "",
        keyBookmark: Data? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.username = username
        self.port = port
        self.authentication = authentication
        self.keyPath = keyPath
        self.keyBookmark = keyBookmark
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, host, username, port, authentication, keyPath, keyBookmark
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        host = try container.decode(String.self, forKey: .host)
        username = try container.decode(String.self, forKey: .username)
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 22
        keyPath = try container.decodeIfPresent(String.self, forKey: .keyPath) ?? ""
        keyBookmark = try container.decodeIfPresent(Data.self, forKey: .keyBookmark)
        // Configurations created before password support only offered SSH keys.
        authentication = try container.decodeIfPresent(RunnerServerAuthentication.self, forKey: .authentication) ?? .sshKey
    }
}

struct RunnerDiscovery: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case service
        case port
    }

    let id: String
    let name: String
    let detail: String
    let symbol: String
    let kind: Kind
}

struct RunnerLibrary: Codable, Sendable {
    var version = 1
    var tasks: [RunnerTask] = []
    var servers: [RunnerServer] = []
    var managedServices: [RunnerManagedService] = []

    init(
        version: Int = 1,
        tasks: [RunnerTask] = [],
        servers: [RunnerServer] = [],
        managedServices: [RunnerManagedService] = []
    ) {
        self.version = version
        self.tasks = tasks
        self.servers = servers
        self.managedServices = managedServices
    }

    private enum CodingKeys: String, CodingKey { case version, tasks, servers, managedServices }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        tasks = try container.decodeIfPresent([RunnerTask].self, forKey: .tasks) ?? []
        servers = try container.decodeIfPresent([RunnerServer].self, forKey: .servers) ?? []
        managedServices = try container.decodeIfPresent([RunnerManagedService].self, forKey: .managedServices) ?? []
    }
}

enum RunnerError: LocalizedError {
    case invalidTask
    case processFailed(String)
    case accessExpired
    case serverConfiguration

    var errorDescription: String? {
        switch self {
        case .invalidTask: "请填写任务名称、运行内容和工作目录。"
        case let .processFailed(message): message.isEmpty ? "操作没有成功完成。" : message
        case .accessExpired: "文件访问授权已失效，请重新选择位置。"
        case .serverConfiguration: "请填写服务器名称、地址、用户名和认证信息。"
        }
    }
}
