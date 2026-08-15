import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class ServerManager: ObservableObject {
    var terminalConnectionHandler: ((Server) -> Void)?
    @Published private(set) var servers: [Server] = []
    @Published private(set) var groups: [ServerGroup] = []
    @Published private(set) var tags: [ServerTag] = []
    @Published private(set) var credentials: [SSHCredential] = []
    @Published private(set) var history: [ConnectionHistory] = []
    @Published private(set) var favoriteServerIDs: Set<UUID> = []
    @Published private(set) var detectedSystems: [UUID: ServerSystemIdentity] = [:]
    @Published private(set) var statuses: [UUID: ServerStatus] = [:]
    @Published var presentedError: ServerPresentedError?
    @Published var periodicChecksEnabled: Bool {
        didSet {
            UserDefaults.standard.set(periodicChecksEnabled, forKey: Self.periodicChecksKey)
            configurePeriodicChecks()
        }
    }

    private static let periodicChecksKey = "serverManager.periodicChecksEnabled"
    private let persistence: ServerPersistence
    private var periodicTask: Task<Void, Never>?
    private var didBootstrap = false

    init(persistence: ServerPersistence = ServerPersistence()) {
        self.persistence = persistence
        periodicChecksEnabled = UserDefaults.standard.bool(forKey: Self.periodicChecksKey)
        do {
            let library = try persistence.loadOrMigrate()
            servers = library.servers
            groups = library.groups.sorted { $0.order < $1.order }
            tags = library.tags
            credentials = library.credentials
            history = library.history
            favoriteServerIDs = Set(library.favoriteServerIDs)
            detectedSystems = library.detectedSystems
        } catch {
            presentedError = ServerPresentedError(error)
        }
    }

    deinit { periodicTask?.cancel() }

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        configurePeriodicChecks()
        await refreshAllStatus()
    }

    func credential(for server: Server) -> SSHCredential? {
        credentials.first { $0.id == server.credentialID }
    }

    func group(for server: Server) -> ServerGroup? {
        groups.first { $0.id == server.groupID }
    }

    func tags(for server: Server) -> [ServerTag] {
        server.tagIDs.compactMap { id in tags.first { $0.id == id } }
    }

    func lastConnection(for server: Server) -> Date? {
        history.filter { $0.serverID == server.id && $0.result == .opened }
            .max(by: { $0.connectedAt < $1.connectedAt })?.connectedAt
    }

    func add(_ server: Server, credential: SSHCredential, password: String?) {
        do {
            if credential.authentication == .password, let password, !password.isEmpty {
                try SSHCredentialStore.savePassword(password, for: server.id)
            }
            servers.append(server)
            credentials.append(credential)
            try save()
        } catch { presentedError = ServerPresentedError(error) }
    }

    func update(_ server: Server, credential: SSHCredential, password: String?) {
        do {
            guard let serverIndex = servers.firstIndex(where: { $0.id == server.id }) else { return }
            servers[serverIndex] = server
            if let credentialIndex = credentials.firstIndex(where: { $0.id == credential.id }) {
                credentials[credentialIndex] = credential
            } else {
                credentials.append(credential)
            }
            if credential.authentication == .password, let password, !password.isEmpty {
                try SSHCredentialStore.savePassword(password, for: server.id)
            }
            try save()
        } catch { presentedError = ServerPresentedError(error) }
    }

    func duplicate(_ source: Server) {
        let id = UUID()
        var copy = source
        copy.id = id
        copy.name += " 副本"
        copy.createdAt = Date()
        copy.updatedAt = Date()
        var credential = self.credential(for: source) ?? SSHCredential(serverID: source.id, authentication: .agent)
        credential.id = UUID()
        credential.serverID = id
        copy.credentialID = credential.id
        if credential.authentication == .password,
           let password = try? RunnerServerCredentialStore.password(for: source.id) {
            try? SSHCredentialStore.savePassword(password, for: id)
        }
        servers.append(copy)
        credentials.append(credential)
        persist()
    }

    func delete(_ server: Server) {
        SSHCredentialStore.deletePassword(for: server.id)
        servers.removeAll { $0.id == server.id }
        credentials.removeAll { $0.serverID == server.id }
        history.removeAll { $0.serverID == server.id }
        statuses[server.id] = nil
        detectedSystems[server.id] = nil
        favoriteServerIDs.remove(server.id)
        persist()
    }

    func isFavorite(_ server: Server) -> Bool {
        favoriteServerIDs.contains(server.id)
    }

    func toggleFavorite(_ server: Server) {
        if favoriteServerIDs.contains(server.id) {
            favoriteServerIDs.remove(server.id)
        } else {
            favoriteServerIDs.insert(server.id)
        }
        persist()
    }

    func move(_ server: Server, to groupID: UUID?) {
        guard let index = servers.firstIndex(where: { $0.id == server.id }) else { return }
        servers[index].groupID = groupID
        servers[index].updatedAt = Date()
        persist()
    }

    @discardableResult
    func createGroup(named rawName: String, parentID: UUID? = nil) -> ServerGroup? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let group = ServerGroup(name: name, parentID: parentID, order: groups.count)
        groups.append(group)
        persist()
        return group
    }

    func renameGroup(_ group: ServerGroup, to rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[index].name = name
        persist()
    }

    func deleteGroup(_ group: ServerGroup) {
        let descendants = descendantGroupIDs(of: group.id).union([group.id])
        groups.removeAll { descendants.contains($0.id) }
        for index in servers.indices where servers[index].groupID.map(descendants.contains) == true {
            servers[index].groupID = nil
        }
        persist()
    }

    func moveGroups(fromOffsets: IndexSet, toOffset: Int) {
        groups.move(fromOffsets: fromOffsets, toOffset: toOffset)
        for index in groups.indices { groups[index].order = index }
        persist()
    }

    func moveGroup(_ movingID: UUID, before targetID: UUID) {
        guard movingID != targetID,
              let source = groups.firstIndex(where: { $0.id == movingID }),
              let destination = groups.firstIndex(where: { $0.id == targetID }) else { return }
        let moving = groups.remove(at: source)
        let adjustedDestination = source < destination ? destination - 1 : destination
        groups.insert(moving, at: adjustedDestination)
        for index in groups.indices { groups[index].order = index }
        persist()
    }

    @discardableResult
    func tag(named rawName: String) -> ServerTag? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        if let existing = tags.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
            return existing
        }
        let tag = ServerTag(name: name)
        tags.append(tag)
        persist()
        return tag
    }

    func deleteTag(_ tag: ServerTag) {
        tags.removeAll { $0.id == tag.id }
        for index in servers.indices { servers[index].tagIDs.removeAll { $0 == tag.id } }
        persist()
    }

    func refreshAllStatus() async {
        await withTaskGroup(of: (UUID, ServerStatus).self) { group in
            for server in servers {
                statuses[server.id] = ServerStatus(
                    availability: .checking,
                    detectedSystem: detectedSystems[server.id]
                )
                let credential = credential(for: server)
                group.addTask { (server.id, await Self.check(server, credential: credential)) }
            }
            for await (id, status) in group { apply(status, to: id) }
        }
    }

    func refreshStatus(for server: Server) async {
        statuses[server.id] = ServerStatus(
            availability: .checking,
            detectedSystem: detectedSystems[server.id]
        )
        apply(await Self.check(server, credential: credential(for: server)), to: server.id)
    }

    private func apply(_ status: ServerStatus, to serverID: UUID) {
        var resolved = status
        if let detectedSystem = status.detectedSystem {
            if detectedSystems[serverID] != detectedSystem {
                detectedSystems[serverID] = detectedSystem
                persist()
            }
        } else {
            resolved.detectedSystem = detectedSystems[serverID]
        }
        statuses[serverID] = resolved
    }

    func connect(to server: Server) {
        guard let terminalConnectionHandler else {
            presentedError = ServerPresentedError("终端模块尚未准备就绪，请稍后重试。")
            return
        }
        terminalConnectionHandler(server)
    }

    func recordTerminalConnection(_ server: Server) {
        recordConnection(server.id, result: .opened)
    }

    func copySSHCommand(for server: Server) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sshCommand(for: server), forType: .string)
    }

    func copyConfiguration(for server: Server) {
        let alias = server.name.lowercased().replacingOccurrences(of: " ", with: "-")
        var lines = [
            "Host \(alias)",
            "  HostName \(server.host)",
            "  User \(server.user)",
            "  Port \(server.port)",
            "  ServerAliveInterval \(server.keepAliveInterval)"
        ]
        if let credential = credential(for: server), credential.authentication == .sshKey, !credential.keyPath.isEmpty {
            lines.append("  IdentityFile \(credential.keyPath)")
        }
        if let jumpHostID = server.jumpHostID, let jump = servers.first(where: { $0.id == jumpHostID }) {
            lines.append("  ProxyJump \(jump.user)@\(jump.host):\(jump.port)")
        }
        let configuration = lines.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(configuration, forType: .string)
    }

    func importSSHConfiguration(from url: URL) {
        do {
            let data = try Data(contentsOf: url)
            guard let source = String(data: data, encoding: .utf8) else {
                throw SSHConfigurationImportError.invalidEncoding
            }

            let imported = Self.parseSSHConfiguration(source).filter { entry in
                !servers.contains {
                    $0.name.localizedCaseInsensitiveCompare(entry.alias) == .orderedSame
                        || ($0.host.localizedCaseInsensitiveCompare(entry.host) == .orderedSame
                            && $0.user == entry.user
                            && $0.port == entry.port)
                }
            }

            guard !imported.isEmpty else {
                throw SSHConfigurationImportError.noNewHosts
            }

            for entry in imported {
                let serverID = UUID()
                let credentialID = UUID()
                let keyPath = entry.identityFile.map {
                    NSString(string: $0).expandingTildeInPath
                } ?? ""
                let authentication: ServerAuthentication = keyPath.isEmpty ? .agent : .sshKey
                let credential = SSHCredential(
                    id: credentialID,
                    serverID: serverID,
                    authentication: authentication,
                    keyPath: keyPath
                )
                let server = Server(
                    id: serverID,
                    name: entry.alias,
                    host: entry.host,
                    user: entry.user,
                    port: entry.port,
                    credentialID: credentialID
                )
                servers.append(server)
                credentials.append(credential)
            }
            try save()
        } catch {
            presentedError = ServerPresentedError(error)
        }
    }

    private static func parseSSHConfiguration(_ source: String) -> [SSHConfigurationEntry] {
        var results: [SSHConfigurationEntry] = []
        var aliases: [String] = []
        var values: [String: String] = [:]

        func finishBlock() {
            guard !aliases.isEmpty else { return }
            for alias in aliases where !alias.contains("*") && !alias.contains("?") && !alias.hasPrefix("!") {
                let host = values["hostname"] ?? alias
                let user = values["user"] ?? NSUserName()
                let port = Int(values["port"] ?? "22") ?? 22
                guard !host.isEmpty, !user.isEmpty, (1...65535).contains(port) else { continue }
                results.append(SSHConfigurationEntry(
                    alias: alias,
                    host: host,
                    user: user,
                    port: port,
                    identityFile: values["identityfile"]
                ))
            }
        }

        for rawLine in source.components(separatedBy: .newlines) {
            let line = rawLine.split(separator: "#", maxSplits: 1).first.map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !line.isEmpty else { continue }
            let parts = line.split(whereSeparator: \Character.isWhitespace).map(String.init)
            guard let directive = parts.first?.lowercased(), parts.count > 1 else { continue }
            if directive == "host" {
                finishBlock()
                aliases = Array(parts.dropFirst())
                values = [:]
            } else if !aliases.isEmpty, ["hostname", "user", "port", "identityfile"].contains(directive) {
                values[directive] = parts.dropFirst().joined(separator: " ")
            }
        }
        finishBlock()
        return results
    }

    private static func check(_ server: Server, credential: SSHCredential?) async -> ServerStatus {
        do {
            let result = try await RunnerCommandExecutor.run(
                executable: "/usr/bin/nc",
                arguments: ["-z", "-G", String(max(1, min(server.connectionTimeout, 10))), server.host, String(server.port)]
            )
            guard result.exitCode == 0 else {
                return ServerStatus(availability: .offline, checkedAt: Date())
            }
            let metrics = await sampleMetrics(server, credential: credential)
            return ServerStatus(
                availability: .online,
                detectedSystem: metrics?.system,
                cpuPercent: metrics?.cpuPercent,
                memoryPercent: metrics?.memoryPercent,
                diskPercent: metrics?.diskPercent,
                checkedAt: Date()
            )
        } catch {
            return ServerStatus(availability: .error, checkedAt: Date())
        }
    }

    private static func sampleMetrics(_ server: Server, credential: SSHCredential?) async -> ServerProbeResult? {
        guard let credential else { return nil }
        var arguments = [
            "-o", credential.authentication == .password ? "BatchMode=no" : "BatchMode=yes",
            "-o", "ConnectTimeout=\(max(1, min(server.connectionTimeout, 8)))",
            "-o", "StrictHostKeyChecking=accept-new",
            "-p", String(server.port)
        ]
        var environment: [String: String]?
        var askPassURL: URL?
        var scopedURL: URL?
        var hasScopedAccess = false
        if credential.authentication == .sshKey {
            guard !credential.keyPath.isEmpty else { return nil }
            let keyURL: URL
            do {
                keyURL = try credential.keyBookmark.map(SecurityScopedBookmarkService.resolve)
                    ?? URL(fileURLWithPath: credential.keyPath)
            } catch { return nil }
            scopedURL = keyURL
            hasScopedAccess = keyURL.startAccessingSecurityScopedResource()
            arguments += ["-i", keyURL.path]
        } else if credential.authentication == .password {
            guard let password = try? RunnerServerCredentialStore.password(for: server.id) else { return nil }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("inchspace-askpass-\(UUID().uuidString).sh")
            let escapedPassword = password.replacingOccurrences(of: "'", with: "'\\''")
            let script = "#!/bin/sh\nprintf '%s\\n' '\(escapedPassword)'\n"
            do {
                try Data(script.utf8).write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            } catch { return nil }
            askPassURL = url
            var values = AppEnvironmentStore.shared.environment()
            values["SSH_ASKPASS"] = url.path
            values["SSH_ASKPASS_REQUIRE"] = "force"
            values["DISPLAY"] = "inchspace:0"
            environment = values
            arguments += ["-o", "NumberOfPasswordPrompts=1"]
        }
        defer {
            if hasScopedAccess { scopedURL?.stopAccessingSecurityScopedResource() }
            if let askPassURL { try? FileManager.default.removeItem(at: askPassURL) }
        }

        let endpoint = "\(server.user)@\(server.host)"
        let unixProbe = "kernel=$(uname -s 2>/dev/null || printf unknown); os=unknown; like=none; if [ -r /etc/os-release ]; then os=$(awk -F= '$1==\"ID\"{gsub(/\"/,\"\",$2); print $2; exit}' /etc/os-release); like=$(awk -F= '$1==\"ID_LIKE\"{gsub(/\"/,\"\",$2); print $2; exit}' /etc/os-release | tr ' ' ','); fi; printf '__INCHSPACE_OS__|%s|%s|%s\\n' \"$kernel\" \"$os\" \"$like\"; cpu=$(awk 'NR==1 {idle=$5+$6; total=0; for(i=2;i<=NF;i++) total+=$i; if(total>0) printf \"%.1f\", (total-idle)*100/total}' /proc/stat 2>/dev/null); mem=$(awk '/MemTotal/{t=$2}/MemAvailable/{a=$2} END{if(t>0) printf \"%.1f\", (t-a)*100/t}' /proc/meminfo 2>/dev/null); disk=$(df -P / 2>/dev/null | awk 'NR==2 {gsub(/%/,\"\",$5); print $5}'); printf '__INCHSPACE_METRICS__|%s|%s|%s\\n' \"$cpu\" \"$mem\" \"$disk\""
        let unixArguments = arguments + [endpoint, unixProbe]
        if let result = try? await RunnerCommandExecutor.run(
            executable: "/usr/bin/ssh",
            arguments: unixArguments,
            environment: environment,
            usesNullInput: credential.authentication == .password
        ),
           result.exitCode == 0,
           let parsed = parseUnixProbe(result.output) {
            return parsed
        }

        let windowsProbe = "powershell -NoProfile -NonInteractive -Command \"$v=(Get-CimInstance Win32_OperatingSystem).Caption; Write-Output ('__INCHSPACE_WINDOWS__|' + $v)\""
        let windowsArguments = arguments + [endpoint, windowsProbe]
        if let result = try? await RunnerCommandExecutor.run(
            executable: "/usr/bin/ssh",
            arguments: windowsArguments,
            environment: environment,
            usesNullInput: credential.authentication == .password
        ), result.exitCode == 0, result.output.contains("__INCHSPACE_WINDOWS__|") {
            return ServerProbeResult(system: .windows)
        }
        return nil
    }

    private static func parseUnixProbe(_ output: String) -> ServerProbeResult? {
        let lines = output.components(separatedBy: .newlines)
        guard let osLine = lines.first(where: { $0.hasPrefix("__INCHSPACE_OS__|") }) else { return nil }
        let osValues = osLine.components(separatedBy: "|")
        guard osValues.count >= 4 else { return nil }
        let metricsLine = lines.first(where: { $0.hasPrefix("__INCHSPACE_METRICS__|") })
        let metricValues = metricsLine?.components(separatedBy: "|") ?? []
        return ServerProbeResult(
            system: detectSystem(kernel: osValues[1], identifier: osValues[2], like: osValues[3]),
            cpuPercent: metricValues.count > 1 ? Double(metricValues[1]) : nil,
            memoryPercent: metricValues.count > 2 ? Double(metricValues[2]) : nil,
            diskPercent: metricValues.count > 3 ? Double(metricValues[3]) : nil
        )
    }

    static func detectSystem(kernel: String, identifier: String, like: String) -> ServerSystemIdentity {
        let id = identifier.lowercased()
        switch id {
        case "ubuntu", "pop", "elementary", "zorin": return .ubuntu
        case "debian": return .debian
        case "fedora": return .fedora
        case "centos": return .centOS
        case "rhel": return .redHat
        case "rocky": return .rockyLinux
        case "almalinux": return .almaLinux
        case "amzn": return .amazonLinux
        case "ol", "oracle": return .oracleLinux
        case "arch": return .archLinux
        case "manjaro": return .manjaro
        case "alpine": return .alpineLinux
        case "opensuse", "opensuse-leap", "opensuse-tumbleweed": return .openSUSE
        case "sles", "sles_sap": return .suseLinux
        case "kali": return .kaliLinux
        case "raspbian": return .raspberryPiOS
        case "linuxmint": return .linuxMint
        case "gentoo": return .gentoo
        case "nixos": return .nixOS
        case "void": return .voidLinux
        default: break
        }
        switch kernel.lowercased() {
        case "darwin": return .macOS
        case "freebsd": return .freeBSD
        case "openbsd": return .openBSD
        case "netbsd": return .netBSD
        case "linux":
            if like.localizedCaseInsensitiveContains("debian") { return .debian }
            if like.localizedCaseInsensitiveContains("rhel") { return .redHat }
            if like.localizedCaseInsensitiveContains("arch") { return .archLinux }
            return .linux
        default: return .unknown
        }
    }

    private func descendantGroupIDs(of id: UUID) -> Set<UUID> {
        var result = Set<UUID>()
        var pending = [id]
        while let parent = pending.popLast() {
            let children = groups.filter { $0.parentID == parent }.map(\.id)
            result.formUnion(children)
            pending.append(contentsOf: children)
        }
        return result
    }

    private func configurePeriodicChecks() {
        periodicTask?.cancel()
        guard periodicChecksEnabled else { return }
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled else { return }
                await self?.refreshAllStatus()
            }
        }
    }

    private func sshCommand(for server: Server) -> String {
        var arguments = ["ssh"]
        if server.port != 22 { arguments += ["-p", String(server.port)] }
        if server.connectionTimeout > 0 { arguments += ["-o", "ConnectTimeout=\(server.connectionTimeout)"] }
        if server.keepAliveInterval > 0 { arguments += ["-o", "ServerAliveInterval=\(server.keepAliveInterval)"] }
        if let credential = credential(for: server), credential.authentication == .sshKey, !credential.keyPath.isEmpty {
            arguments += ["-i", shellQuote(credential.keyPath)]
        }
        if let jumpHostID = server.jumpHostID, let jump = servers.first(where: { $0.id == jumpHostID }) {
            arguments += ["-J", shellQuote("\(jump.user)@\(jump.host):\(jump.port)")]
        }
        arguments.append(shellQuote("\(server.user)@\(server.host)"))
        return arguments.joined(separator: " ")
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func recordConnection(_ serverID: UUID, result: ConnectionHistory.Result) {
        history.insert(ConnectionHistory(serverID: serverID, result: result), at: 0)
        if history.count > 500 { history = Array(history.prefix(500)) }
        persist()
    }

    private func persist() {
        do { try save() }
        catch { presentedError = ServerPresentedError(error) }
    }

    private func save() throws {
        try persistence.save(ServerLibrary(
            servers: servers,
            groups: groups,
            tags: tags,
            credentials: credentials,
            history: history,
            favoriteServerIDs: Array(favoriteServerIDs),
            detectedSystems: detectedSystems
        ))
    }
}

private struct SSHConfigurationEntry {
    let alias: String
    let host: String
    let user: String
    let port: Int
    let identityFile: String?
}

private struct ServerProbeResult {
    let system: ServerSystemIdentity
    var cpuPercent: Double? = nil
    var memoryPercent: Double? = nil
    var diskPercent: Double? = nil
}

private enum SSHConfigurationImportError: LocalizedError {
    case invalidEncoding
    case noNewHosts

    var errorDescription: String? {
        switch self {
        case .invalidEncoding:
            "SSH 配置文件不是有效的 UTF-8 文本。"
        case .noNewHosts:
            "没有找到可导入的新 Host 条目。通配符与重复主机会被自动跳过。"
        }
    }
}
