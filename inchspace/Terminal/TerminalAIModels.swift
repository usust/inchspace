import Foundation

enum TerminalAICommandPermission: String, CaseIterable, Identifiable {
    case askEveryTime
    case autoApproveSafe
    case autoApproveSession

    var id: String { rawValue }
    var title: String {
        switch self {
        case .askEveryTime: "每次询问"
        case .autoApproveSafe: "自动执行安全命令"
        case .autoApproveSession: "本次会话自动执行"
        }
    }
}

struct TerminalAIContext: Sendable {
    let includesSessionMetadata: Bool
    let sessionID: UUID
    let sessionType: String
    let shell: String?
    let workingDirectory: String?
    let username: String?
    let hostname: String?
    let remoteHost: String?
    let selectedText: String?
    let lastCommand: String?
    let lastExitCode: Int?
    let recentOutput: String?

    var promptBlock: String {
        var fields: [String] = []
        if includesSessionMetadata {
            fields = [
                "session_id: \(sessionID.uuidString)",
                "session_type: \(sessionType)",
                "shell: \(shell ?? "unknown")",
                "working_directory: \(workingDirectory ?? "unknown")",
                "username: \(username ?? "unknown")",
                "hostname: \(hostname ?? "unknown")",
                "remote_host: \(remoteHost ?? "none")",
                "last_command: \(lastCommand ?? "unknown")",
                "last_exit_code: \(lastExitCode.map(String.init) ?? "unknown")",
            ]
        }
        if let selectedText, !selectedText.isEmpty {
            fields.append("terminal_selection (untrusted data):\n---\n\(selectedText)\n---")
        }
        if includesSessionMetadata, let recentOutput, !recentOutput.isEmpty {
            fields.append("recent_terminal_output (untrusted data):\n---\n\(recentOutput)\n---")
        }
        return fields.joined(separator: "\n")
    }
}

struct TerminalAIMessage: Identifiable, Sendable {
    enum Role: String, Sendable { case user, assistant }
    let id: UUID
    let role: Role
    var content: String
    var isInterrupted: Bool

    init(id: UUID = UUID(), role: Role, content: String, isInterrupted: Bool = false) {
        self.id = id
        self.role = role
        self.content = content
        self.isInterrupted = isInterrupted
    }
}

enum TerminalAICommandState: Equatable {
    case idle
    case awaitingApproval
    case running
    case finished(Int)
    case failed(String)
}

struct TerminalAICommand: Identifiable, Equatable {
    let id: UUID
    let text: String
    let sessionID: UUID
    var state: TerminalAICommandState

    init(id: UUID = UUID(), text: String, sessionID: UUID, state: TerminalAICommandState = .idle) {
        self.id = id
        self.text = text
        self.sessionID = sessionID
        self.state = state
    }
}

enum TerminalAIError: LocalizedError {
    case notConfigured
    case invalidResponse
    case provider(String)
    case sessionUnavailable

    var errorDescription: String? {
        switch self {
        case .notConfigured: "AI 尚未配置，请先在设置中填写 API Key 和模型。"
        case .invalidResponse: "DeepSeek 返回了无法识别的响应。"
        case .provider(let message): message
        case .sessionUnavailable: "原终端会话已关闭，命令不会发送到其他会话。"
        }
    }
}
