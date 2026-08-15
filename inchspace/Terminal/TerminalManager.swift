import Combine
import Foundation
import SwiftTerm

@MainActor
final class TerminalManager: ObservableObject {
    @Published private(set) var sessions: [TerminalSession] = []
    @Published var selectedSessionID: UUID?

    let preferences: TerminalPreferences
    private var sessionObservers: [UUID: AnyCancellable] = [:]

    init(preferences: TerminalPreferences? = nil) {
        self.preferences = preferences ?? TerminalPreferences()
    }

    var selectedSession: TerminalSession? {
        session(id: selectedSessionID)
    }

    @discardableResult
    func openLocalSession(directory: String? = nil) -> TerminalSession {
        makeLocalSession(directory: directory, selects: true)
    }

    @discardableResult
    func openRemoteSession(
        server: Server,
        credential: SSHCredential?,
        jumpHost: Server?
    ) -> TerminalSession {
        let session = TerminalSession(
            title: server.name,
            kind: .ssh(serverID: server.id, endpoint: server.endpoint),
            preferences: preferences
        ) { _ in
            try SSHConnectionManager.configuration(
                server: server,
                credential: credential,
                jumpHost: jumpHost
            )
        }
        sessions.append(session)
        observe(session)
        selectedSessionID = session.id
        return session
    }

    func select(_ id: UUID) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        selectedSessionID = id
        selectedSession?.focus()
    }

    func close(_ session: TerminalSession) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        session.terminate()
        sessions.remove(at: index)
        sessionObservers[session.id] = nil
        if selectedSessionID == session.id {
            selectedSessionID = sessions.indices.contains(index)
                ? sessions[index].id
                : sessions.last?.id
        }
    }

    func split(_ orientation: TerminalSplitOrientation) {
        guard let session = selectedSession else {
            _ = openLocalSession()
            return
        }
        session.split(orientation)
    }

    func closeActivePane() {
        guard let session = selectedSession else { return }
        if !session.closePane(session.activePaneID) {
            close(session)
        }
    }

    func reconnectSelected() {
        selectedSession?.activePane.reconnect()
    }

    func applyPreferences() {
        sessions.forEach { $0.applyAppearance() }
    }

    /// Reloads a user Shell configuration in the currently active local terminal.
    /// Running remote sessions are intentionally excluded because the URL belongs to this Mac.
    @discardableResult
    func sourceEnvironmentFile(_ url: URL) -> Bool {
        guard let session = selectedSession,
              case .local = session.kind,
              session.activePane.isRunning else { return false }
        let quotedPath = "'" + url.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let command = "source \(quotedPath)\r"
        let bytes = Array(command.utf8)
        session.activePane.terminalView.send(source: session.activePane.terminalView, data: bytes[...])
        return true
    }

    func session(id: UUID?) -> TerminalSession? {
        guard let id else { return nil }
        return sessions.first { $0.id == id }
    }

    private func makeLocalSession(directory: String?, selects: Bool) -> TerminalSession {
        let shell = preferences.resolvedShell
        let shellName = URL(fileURLWithPath: shell).lastPathComponent
        let resolvedDirectory = directory ?? preferences.workingDirectory
        let sessionPreferences = preferences
        let session = TerminalSession(
            title: "本机 — \(shellName)",
            kind: .local(shell: shell),
            preferences: preferences
        ) { inheritedDirectory in
            var environment = AppEnvironmentStore.shared.environment()
            environment["TERM"] = "xterm-256color"
            environment["COLORTERM"] = "truecolor"
            // Theme palettes only map ANSI indices to colors; programs still
            // need to emit ANSI sequences. These variables enable the native
            // macOS/BSD `ls` color path even when clean startup skips .zshrc.
            environment["CLICOLOR"] = "1"
            environment["LSCOLORS"] = "GxFxCxDxBxegedabagaced"
            environment["LS_COLORS"] = "di=1;36:ln=35:so=32:pi=33:ex=1;32:bd=34;46:cd=34;43:su=30;41:sg=30;46:tw=30;42:ow=30;43"
            environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
            environment["HOME"] = environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
            environment["USER"] = environment["USER"] ?? NSUserName()
            environment["PATH"] = environment["PATH"]
                ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            let prompt = Self.prompt(for: shellName, preferences: sessionPreferences)
            environment["PS1"] = prompt
            environment["PROMPT"] = prompt
            environment["HISTFILE"] = sessionPreferences.cleanShellStartup ? "/dev/null" : environment["HISTFILE"]
            return TerminalProcessConfiguration(
                executable: shell,
                arguments: Self.shellArguments(for: shellName, cleanStartup: sessionPreferences.cleanShellStartup),
                environment: environment.map { "\($0.key)=\($0.value)" }.sorted(),
                execName: sessionPreferences.cleanShellStartup ? shellName : "-\(shellName)",
                currentDirectory: inheritedDirectory ?? resolvedDirectory,
                resource: nil
            )
        }
        sessions.append(session)
        observe(session)
        if selects { selectedSessionID = session.id }
        return session
    }

    private static func shellArguments(for shellName: String, cleanStartup: Bool) -> [String] {
        guard cleanStartup else { return [] }
        switch shellName {
        case "zsh": return ["-f"]
        case "bash": return ["--noprofile", "--norc"]
        default: return []
        }
    }

    private static func prompt(for shellName: String, preferences: TerminalPreferences) -> String {
        let isZsh = shellName == "zsh"
        let accentStart = isZsh ? "%F{blue}" : "\\[\\e[34m\\]"
        let accentEnd = isZsh ? "%f" : "\\[\\e[0m\\]"
        switch preferences.promptStyle {
        case .chevron:
            return "\(accentStart)❯\(accentEnd) "
        case .custom:
            return preferences.customPrompt.isEmpty ? "❯ " : preferences.customPrompt
        case .userAndHost:
            return isZsh
                ? "\(accentStart)%n@%m\(accentEnd) %# "
                : "\(accentStart)\\u@\\h\(accentEnd) \\$ "
        case .compactPath:
            return isZsh
                ? "\(accentStart)%1~ ❯\(accentEnd) "
                : "\(accentStart)\\W ❯\(accentEnd) "
        }
    }

    private func observe(_ session: TerminalSession) {
        sessionObservers[session.id] = session.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }
}
