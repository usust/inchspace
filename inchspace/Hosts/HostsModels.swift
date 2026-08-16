import Foundation

nonisolated struct HostEntry: Identifiable, Hashable, Sendable {
    let id: UUID
    var address: String
    var hostnames: [String]
    var comment: String
    var enabled: Bool
    var isSystem: Bool
    var lineIndex: Int

    var hostnameText: String { hostnames.joined(separator: " ") }
}

nonisolated struct HostsLine: Identifiable, Hashable, Sendable {
    let id: UUID
    var raw: String
    var entry: HostEntry?
}

nonisolated struct HostsDocument: Sendable {
    var lines: [HostsLine]
    var endsWithNewline: Bool

    var entries: [HostEntry] { lines.compactMap(\.entry) }
    var rendered: String { lines.map(\.raw).joined(separator: "\n") + (endsWithNewline ? "\n" : "") }
}

enum HostsFilter: String, CaseIterable, Identifiable {
    case all, enabled, disabled
    var id: String { rawValue }
    var title: String { switch self { case .all: "全部"; case .enabled: "启用"; case .disabled: "停用" } }
}

enum HostsError: LocalizedError {
    case invalidAddress, invalidHostname(String), protectedSystemEntry, entryNotFound
    case fileTooLarge, invalidContent, authorizationCancelled, writeFailed(String), backupNotFound

    var errorDescription: String? {
        switch self {
        case .invalidAddress: "请输入有效的 IPv4 或 IPv6 地址。"
        case .invalidHostname(let name): "Hostname“\(name)”格式无效。"
        case .protectedSystemEntry: "这是 macOS 系统 Hosts 项，不能删除或停用。"
        case .entryNotFound: "该 Hosts 项已不存在，请刷新后重试。"
        case .fileTooLarge: "Hosts 文件异常过大，已停止写入。"
        case .invalidContent: "Hosts 内容未通过安全校验。"
        case .authorizationCancelled: "已取消管理员授权。"
        case .writeFailed(let message): "无法保存 /etc/hosts：\(message)"
        case .backupNotFound: "所选备份不存在。"
        }
    }
}
