import Foundation

enum FileItemKind: String, Sendable {
    case file, directory, symbolicLink
}

struct FileItem: Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var path: String
    var kind: FileItemKind
    var size: Int64
    var modifiedAt: Date?
    var permissions: String?
    var linkTarget: String?

    init(name: String, path: String, kind: FileItemKind, size: Int64 = 0, modifiedAt: Date? = nil, permissions: String? = nil, linkTarget: String? = nil) {
        id = path
        self.name = name
        self.path = path
        self.kind = kind
        self.size = size
        self.modifiedAt = modifiedAt
        self.permissions = permissions
        self.linkTarget = linkTarget
    }
}

enum RemoteConnectionState: Equatable {
    case disconnected, connecting, connected, failed(String)

    var title: String {
        switch self {
        case .disconnected: "未连接"
        case .connecting: "正在连接…"
        case .connected: "已连接"
        case .failed(let reason): reason
        }
    }
}

struct PendingHostTrust: Identifiable, Sendable {
    let id = UUID()
    let host: String
    let algorithm: String
    let fingerprint: String
    let keyLine: String
    let changed: Bool
}

enum TransferDirection: String, Sendable {
    case upload, download
    var symbol: String { self == .upload ? "arrow.up" : "arrow.down" }
}

enum TransferState: String, Sendable {
    case waiting, transferring, completed, failed, cancelled
    var title: String {
        switch self {
        case .waiting: "等待中"
        case .transferring: "传输中"
        case .completed: "已完成"
        case .failed: "失败"
        case .cancelled: "已取消"
        }
    }
}

struct FileTransfer: Identifiable, Sendable {
    let id: UUID
    let direction: TransferDirection
    let source: String
    let destination: String
    let filename: String
    var totalBytes: Int64
    var transferredBytes: Int64
    var bytesPerSecond: Double
    var state: TransferState
    var error: String?

    var progress: Double { totalBytes > 0 ? min(1, Double(transferredBytes) / Double(totalBytes)) : 0 }
    var eta: TimeInterval? { bytesPerSecond > 1024 ? Double(max(0, totalBytes - transferredBytes)) / bytesPerSecond : nil }
}

enum TransferConflictChoice: String, CaseIterable, Identifiable {
    case cancel, keepBoth, replace
    var id: String { rawValue }
}

struct PendingTransferConflict: Identifiable {
    let id = UUID()
    let direction: TransferDirection
    let item: FileItem
    let destination: String
    let existingSize: Int64
}

struct FileNamePrompt: Identifiable {
    enum Kind: Equatable { case createDirectory, rename }
    let id = UUID()
    let kind: Kind
    let isLocal: Bool
    let item: FileItem?
    var name: String
}

enum RemoteFileError: LocalizedError {
    case noServer, hostNotTrusted(PendingHostTrust), hostKeyChanged(PendingHostTrust)
    case authenticationFailed, timeout, permissionDenied, processFailed(String), invalidListing

    var errorDescription: String? {
        switch self {
        case .noServer: "请先选择服务器。"
        case .hostNotTrusted: "无法验证服务器身份。"
        case .hostKeyChanged: "服务器 Host Key 与已信任的记录不匹配。"
        case .authenticationFailed: "认证失败，请检查服务器凭据。"
        case .timeout: "连接超时，请检查网络和服务器地址。"
        case .permissionDenied: "没有权限执行此操作。"
        case .processFailed(let message): message
        case .invalidListing: "无法解析服务器返回的目录信息。"
        }
    }
}
