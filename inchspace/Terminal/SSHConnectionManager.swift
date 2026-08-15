import Foundation

struct TerminalProcessConfiguration {
    let executable: String
    let arguments: [String]
    let environment: [String]?
    let execName: String?
    let currentDirectory: String?
    let resource: TerminalConnectionResource?
}

final class TerminalConnectionResource {
    private let securityScopedURL: URL?
    private let temporaryURL: URL?
    private var isFinished = false

    init(securityScopedURL: URL? = nil, temporaryURL: URL? = nil) {
        self.securityScopedURL = securityScopedURL
        self.temporaryURL = temporaryURL
    }

    func finish() {
        guard !isFinished else { return }
        isFinished = true
        securityScopedURL?.stopAccessingSecurityScopedResource()
        if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
    }

    deinit { finish() }
}

enum SSHConnectionManager {
    static func configuration(
        server: Server,
        credential: SSHCredential?,
        jumpHost: Server?
    ) throws -> TerminalProcessConfiguration {
        var arguments = [
            "-o", "ConnectTimeout=\(max(1, server.connectionTimeout))",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ServerAliveInterval=\(max(0, server.keepAliveInterval))",
            "-p", String(server.port)
        ]
        var environment = AppEnvironmentStore.shared.environment()
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"

        var scopedURL: URL?
        var askPassURL: URL?

        if let credential {
            switch credential.authentication {
            case .sshKey:
                guard !credential.keyPath.isEmpty else {
                    throw SSHConnectionPreparationError.missingKey
                }
                let keyURL = try credential.keyBookmark.map(SecurityScopedBookmarkService.resolve)
                    ?? URL(fileURLWithPath: credential.keyPath)
                if keyURL.startAccessingSecurityScopedResource() { scopedURL = keyURL }
                arguments += ["-i", keyURL.path]
            case .password:
                let password = try RunnerServerCredentialStore.password(for: server.id)
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("inchspace-terminal-askpass-\(UUID().uuidString).sh")
                let escaped = password.replacingOccurrences(of: "'", with: "'\\''")
                let script = "#!/bin/sh\nprintf '%s\\n' '\(escaped)'\n"
                try Data(script.utf8).write(to: url, options: [.atomic, .completeFileProtection])
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
                askPassURL = url
                environment["SSH_ASKPASS"] = url.path
                environment["SSH_ASKPASS_REQUIRE"] = "force"
                environment["DISPLAY"] = "inchspace:0"
                arguments += ["-o", "NumberOfPasswordPrompts=1"]
            case .agent:
                break
            }
        }

        if let jumpHost {
            arguments += ["-J", "\(jumpHost.user)@\(jumpHost.host):\(jumpHost.port)"]
        }
        arguments.append("\(server.user)@\(server.host)")

        let environmentList = environment
            .map { "\($0.key)=\($0.value)" }
            .sorted()
        return TerminalProcessConfiguration(
            executable: "/usr/bin/ssh",
            arguments: arguments,
            environment: environmentList,
            execName: "ssh",
            currentDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
            resource: TerminalConnectionResource(securityScopedURL: scopedURL, temporaryURL: askPassURL)
        )
    }
}

private enum SSHConnectionPreparationError: LocalizedError {
    case missingKey

    var errorDescription: String? {
        switch self {
        case .missingKey: "该服务器没有可用的 SSH 私钥。"
        }
    }
}
