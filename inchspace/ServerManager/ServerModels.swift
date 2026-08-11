import Foundation

enum ServerAuthentication: String, Codable, CaseIterable, Identifiable, Sendable {
    case sshKey
    case password
    case agent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sshKey: "SSH Key"
        case .password: "密码"
        case .agent: "SSH Agent"
        }
    }

    var symbol: String {
        switch self {
        case .sshKey: "key.horizontal"
        case .password: "ellipsis.rectangle"
        case .agent: "person.badge.key"
        }
    }
}

enum ServerOperatingSystem: String, Codable, CaseIterable, Identifiable, Sendable {
    case ubuntu
    case linux
    case macOS
    case unix
    case unknown

    var id: String { rawValue }
    var title: String {
        switch self {
        case .ubuntu: "Ubuntu"
        case .linux: "Linux"
        case .macOS: "macOS"
        case .unix: "Unix"
        case .unknown: "其他"
        }
    }

    var symbol: String {
        switch self {
        case .ubuntu: "circle.hexagongrid.fill"
        case .linux: "terminal"
        case .macOS: "apple.logo"
        case .unix: "chevron.left.forwardslash.chevron.right"
        case .unknown: "server.rack"
        }
    }
}

struct Server: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var host: String
    var user: String
    var port = 22
    var groupID: UUID?
    var tagIDs: [UUID] = []
    var credentialID: UUID
    var operatingSystem: ServerOperatingSystem = .linux
    var jumpHostID: UUID?
    var connectionTimeout = 8
    var keepAliveInterval = 60
    var notes = ""
    var createdAt = Date()
    var updatedAt = Date()

    var endpoint: String { "\(user)@\(host):\(port)" }
    var sshCommand: String {
        var values = ["ssh"]
        if port != 22 { values += ["-p", String(port)] }
        if keepAliveInterval > 0 { values += ["-o", "ServerAliveInterval=\(keepAliveInterval)"] }
        values.append("\(user)@\(host)")
        return values.joined(separator: " ")
    }
}

struct ServerGroup: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var parentID: UUID?
    var order: Int
}

struct ServerTag: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
}

struct SSHCredential: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var serverID: UUID
    var authentication: ServerAuthentication
    var keyPath = ""
    var keyBookmark: Data?
}

struct ConnectionHistory: Codable, Identifiable, Hashable, Sendable {
    enum Result: String, Codable, Sendable {
        case opened
        case failed
    }

    var id = UUID()
    var serverID: UUID
    var connectedAt = Date()
    var result: Result
}

enum ServerAvailability: String, Codable, Sendable {
    case unknown
    case checking
    case online
    case offline
    case error

    var title: String {
        switch self {
        case .unknown: "未检测"
        case .checking: "检测中"
        case .online: "在线"
        case .offline: "离线"
        case .error: "异常"
        }
    }
}

struct ServerStatus: Sendable {
    var availability: ServerAvailability = .unknown
    var detectedSystem: ServerSystemIdentity?
    var cpuPercent: Double?
    var memoryPercent: Double?
    var diskPercent: Double?
    var checkedAt: Date?
}

enum ServerSystemIdentity: String, Codable, Sendable, Hashable {
    case ubuntu
    case debian
    case fedora
    case centOS
    case redHat
    case rockyLinux
    case almaLinux
    case amazonLinux
    case oracleLinux
    case archLinux
    case manjaro
    case alpineLinux
    case openSUSE
    case suseLinux
    case kaliLinux
    case raspberryPiOS
    case linuxMint
    case gentoo
    case nixOS
    case voidLinux
    case linux
    case macOS
    case windows
    case freeBSD
    case openBSD
    case netBSD
    case unknown

    var title: String {
        switch self {
        case .ubuntu: "Ubuntu"
        case .debian: "Debian"
        case .fedora: "Fedora"
        case .centOS: "CentOS"
        case .redHat: "Red Hat Enterprise Linux"
        case .rockyLinux: "Rocky Linux"
        case .almaLinux: "AlmaLinux"
        case .amazonLinux: "Amazon Linux"
        case .oracleLinux: "Oracle Linux"
        case .archLinux: "Arch Linux"
        case .manjaro: "Manjaro"
        case .alpineLinux: "Alpine Linux"
        case .openSUSE: "openSUSE"
        case .suseLinux: "SUSE Linux Enterprise"
        case .kaliLinux: "Kali Linux"
        case .raspberryPiOS: "Raspberry Pi OS"
        case .linuxMint: "Linux Mint"
        case .gentoo: "Gentoo"
        case .nixOS: "NixOS"
        case .voidLinux: "Void Linux"
        case .linux: "Linux"
        case .macOS: "macOS"
        case .windows: "Windows"
        case .freeBSD: "FreeBSD"
        case .openBSD: "OpenBSD"
        case .netBSD: "NetBSD"
        case .unknown: "未识别"
        }
    }

    var assetName: String? {
        switch self {
        case .ubuntu: "ServerOSUbuntu"
        case .debian: "ServerOSDebian"
        case .fedora: "ServerOSFedora"
        case .centOS: "ServerOSCentOS"
        case .redHat: "ServerOSRedHat"
        case .rockyLinux: "ServerOSRockyLinux"
        case .almaLinux: "ServerOSAlmaLinux"
        case .archLinux: "ServerOSArchLinux"
        case .manjaro: "ServerOSManjaro"
        case .alpineLinux: "ServerOSAlpineLinux"
        case .openSUSE, .suseLinux: "ServerOSOpenSUSE"
        case .kaliLinux: "ServerOSKaliLinux"
        case .raspberryPiOS: "ServerOSRaspberryPi"
        case .linuxMint: "ServerOSLinuxMint"
        case .gentoo: "ServerOSGentoo"
        case .nixOS: "ServerOSNixOS"
        case .voidLinux: "ServerOSVoidLinux"
        case .linux, .amazonLinux, .oracleLinux: "ServerOSLinux"
        case .freeBSD: "ServerOSFreeBSD"
        case .openBSD: "ServerOSOpenBSD"
        case .netBSD: "ServerOSNetBSD"
        case .macOS, .windows, .unknown: nil
        }
    }
}

struct ServerLibrary: Codable, Sendable {
    var version = 1
    var servers: [Server] = []
    var groups: [ServerGroup] = []
    var tags: [ServerTag] = []
    var credentials: [SSHCredential] = []
    var history: [ConnectionHistory] = []
    var favoriteServerIDs: [UUID] = []
    var detectedSystems: [UUID: ServerSystemIdentity] = [:]

    private enum CodingKeys: String, CodingKey {
        case version, servers, groups, tags, credentials, history, favoriteServerIDs, detectedSystems
    }

    init(
        version: Int = 1,
        servers: [Server] = [],
        groups: [ServerGroup] = [],
        tags: [ServerTag] = [],
        credentials: [SSHCredential] = [],
        history: [ConnectionHistory] = [],
        favoriteServerIDs: [UUID] = [],
        detectedSystems: [UUID: ServerSystemIdentity] = [:]
    ) {
        self.version = version
        self.servers = servers
        self.groups = groups
        self.tags = tags
        self.credentials = credentials
        self.history = history
        self.favoriteServerIDs = favoriteServerIDs
        self.detectedSystems = detectedSystems
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        servers = try container.decodeIfPresent([Server].self, forKey: .servers) ?? []
        groups = try container.decodeIfPresent([ServerGroup].self, forKey: .groups) ?? []
        tags = try container.decodeIfPresent([ServerTag].self, forKey: .tags) ?? []
        credentials = try container.decodeIfPresent([SSHCredential].self, forKey: .credentials) ?? []
        history = try container.decodeIfPresent([ConnectionHistory].self, forKey: .history) ?? []
        favoriteServerIDs = try container.decodeIfPresent([UUID].self, forKey: .favoriteServerIDs) ?? []
        detectedSystems = try container.decodeIfPresent([UUID: ServerSystemIdentity].self, forKey: .detectedSystems) ?? [:]
    }
}

struct ServerPresentedError: Identifiable {
    let id = UUID()
    let title: String
    let message: String

    init(_ message: String, title: String = "无法完成操作") {
        self.title = title
        self.message = message
    }

    init(_ error: Error) {
        title = "无法完成操作"
        message = error.localizedDescription
    }
}
