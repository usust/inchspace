import Foundation

@MainActor
final class RemoteFileService {
    private(set) var server: Server?
    private var credential: SSHCredential?
    private var acceptedKeyLine: String?
    private var passwordScriptURL: URL?
    private var securityScopedKeyURL: URL?

    private static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "inchspace/RemoteFiles", directoryHint: .isDirectory)
    }
    private static var knownHostsURL: URL { supportDirectory.appending(path: "known_hosts") }
    private static let listingPattern = try? NSRegularExpression(
        pattern: #"^([bcdlps-][rwxStTs-]{9}[+@.]?)\s+\S+\s+\S+\s+\S+\s+(\d+)\s+(\S+)\s+(\d{1,2})\s+(\S+)\s+(.+)$"#
    )
    private static let recentListingDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy MMM d HH:mm"
        return formatter
    }()
    private static let historicalListingDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "MMM d yyyy"
        return formatter
    }()
    private static func controlPath(for server: Server) -> String {
        // Unix-domain socket paths are limited to roughly 100 bytes on macOS.
        // Keep this out of the much longer Application Support path.
        FileManager.default.temporaryDirectory
            .appending(path: "inchspace-ssh-\(server.id.uuidString.prefix(12))")
            .path
    }

    func preflight(server: Server, credential: SSHCredential?) async throws -> PendingHostTrust? {
        let scan = try await OpenSSHProcess.run(
            executable: "/usr/bin/ssh-keyscan",
            arguments: ["-T", String(max(2, server.connectionTimeout)), "-p", String(server.port), server.host]
        )
        let lines = scan.output.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("#") }
        guard let keyLine = preferredKeyLine(lines) else {
            throw classify(scan.output.isEmpty ? "无法从服务器读取 Host Key。" : scan.output)
        }
        let fields = keyLine.split(separator: " ")
        guard fields.count >= 3 else { throw RemoteFileError.processFailed("服务器返回了无效的 Host Key。") }
        let fingerprint = try await fingerprint(for: keyLine)
        let hostToken = server.port == 22 ? server.host : "[\(server.host)]:\(server.port)"
        let normalized = "\(hostToken) \(fields[1]) \(fields[2])"
        let known = (try? String(contentsOf: Self.knownHostsURL, encoding: .utf8)) ?? ""
        let matchingHostLines = known.split(separator: "\n").map(String.init).filter { $0.split(separator: " ").first == Substring(hostToken) }
        if matchingHostLines.contains(where: { $0 == normalized }) {
            acceptedKeyLine = normalized
            return nil
        }
        return PendingHostTrust(
            host: server.host,
            algorithm: String(fields[1]).replacingOccurrences(of: "ssh-", with: "").uppercased(),
            fingerprint: fingerprint,
            keyLine: normalized,
            changed: !matchingHostLines.isEmpty
        )
    }

    func trust(_ request: PendingHostTrust) throws {
        try FileManager.default.createDirectory(at: Self.supportDirectory, withIntermediateDirectories: true)
        var lines = ((try? String(contentsOf: Self.knownHostsURL, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
        let token = request.keyLine.split(separator: " ").first.map(String.init) ?? request.host
        lines.removeAll { $0.split(separator: " ").first.map(String.init) == token }
        lines.append(request.keyLine)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: Self.knownHostsURL, options: .atomic)
        acceptedKeyLine = request.keyLine
    }

    func connect(server: Server, credential: SSHCredential?) async throws -> String {
        disconnect()
        if let trust = try await preflight(server: server, credential: credential) {
            throw trust.changed ? RemoteFileError.hostKeyChanged(trust) : RemoteFileError.hostNotTrusted(trust)
        }
        self.server = server
        self.credential = credential
        try prepareCredential()
        let result = try await runSFTP("pwd\n")
        guard result.status == 0 else { disconnect(); throw classify(result.output) }
        let pattern = #"Remote working directory: (.+)"#
        if let match = result.output.range(of: pattern, options: .regularExpression) {
            return String(result.output[match]).replacingOccurrences(of: "Remote working directory: ", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "."
    }

    func disconnect() {
        if let server {
            let arguments = ["-S", Self.controlPath(for: server), "-p", String(server.port), "-O", "exit", "\(server.user)@\(server.host)"]
            Task { _ = try? await OpenSSHProcess.run(executable: "/usr/bin/ssh", arguments: arguments) }
        }
        server = nil
        credential = nil
        acceptedKeyLine = nil
        if let url = passwordScriptURL { try? FileManager.default.removeItem(at: url) }
        passwordScriptURL = nil
        securityScopedKeyURL?.stopAccessingSecurityScopedResource()
        securityScopedKeyURL = nil
    }

    func list(_ path: String, showsHiddenFiles: Bool) async throws -> [FileItem] {
        // `cd` follows directory symlinks and also verifies that the target is
        // actually a readable directory before returning any listing rows.
        let result = try await runSFTP("cd \(quote(path))\nls -la .\n")
        guard result.status == 0 else { throw classify(result.output) }
        return result.output.split(separator: "\n").compactMap { Self.parseListingLine(String($0), parent: path) }
            .filter { $0.name != "." && $0.name != ".." && (showsHiddenFiles || !$0.name.hasPrefix(".")) }
            .sorted(by: FileItem.defaultOrder)
    }

    func createDirectory(named name: String, in path: String) async throws {
        try await checked("mkdir \(quote(join(path, name)))\n")
    }

    func rename(_ item: FileItem, to name: String) async throws {
        try await checked("rename \(quote(item.path)) \(quote(join(parent(of: item.path), name)))\n")
    }

    func delete(_ items: [FileItem]) async throws {
        for item in items {
            try await removeRemoteItem(item)
        }
    }

    func exists(_ path: String) async -> Bool {
        (try? await runSFTP("ls -ld \(quote(path))\n").status) == 0
    }

    func remoteSize(_ path: String) async -> Int64 {
        guard let line = try? await runSFTP("ls -ld \(quote(path))\n").output.split(separator: "\n").last,
              let item = Self.parseListingLine(String(line), parent: parent(of: path)) else { return 0 }
        return item.size
    }

    func treeSize(_ item: FileItem) async -> Int64 {
        guard item.kind == .directory else { return item.size }
        guard let children = try? await list(item.path, showsHiddenFiles: true) else { return 0 }
        var total: Int64 = 0
        for child in children {
            if Task.isCancelled { return total }
            total += child.kind == .directory ? await treeSize(child) : child.size
        }
        return total
    }

    func upload(localPath: String, remotePath: String, cancellation: CancellableProcess) async throws {
        let isDirectory = (try? URL(fileURLWithPath: localPath).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let temporary = join(parent(of: remotePath), ".\(URL(fileURLWithPath: remotePath).lastPathComponent).inchspace-transfer")
        if let staleItem = try? await item(at: temporary) { try? await removeRemoteItem(staleItem) }
        let command = "put \(isDirectory ? "-r " : "")\(quote(localPath)) \(quote(temporary))\nrename \(quote(temporary)) \(quote(remotePath))\n"
        let result = try await runSFTP(command, cancellation: cancellation)
        guard result.status == 0 else { throw classify(result.output) }
    }

    func download(remotePath: String, localPath: String, isDirectory: Bool, cancellation: CancellableProcess) async throws {
        let temporary = URL(fileURLWithPath: localPath).deletingLastPathComponent()
            .appending(path: ".\(URL(fileURLWithPath: localPath).lastPathComponent).inchspace-transfer").path
        try? FileManager.default.removeItem(atPath: temporary)
        let result = try await runSFTP("get \(isDirectory ? "-r " : "")\(quote(remotePath)) \(quote(temporary))\n", cancellation: cancellation)
        guard result.status == 0 else { throw classify(result.output) }
        try FileManager.default.moveItem(atPath: temporary, toPath: localPath)
    }

    private func checked(_ command: String) async throws {
        let result = try await runSFTP(command)
        guard result.status == 0 else { throw classify(result.output) }
    }

    private func item(at path: String) async throws -> FileItem {
        let result = try await runSFTP("ls -ld \(quote(path))\n")
        guard result.status == 0 else { throw classify(result.output) }
        guard let parsed = result.output.split(separator: "\n")
            .compactMap({ Self.parseListingLine(String($0), parent: parent(of: path)) })
            .last else {
            throw RemoteFileError.processFailed("无法读取远程项目：\(path)")
        }
        return FileItem(
            name: (path as NSString).lastPathComponent,
            path: path,
            kind: parsed.kind,
            size: parsed.size,
            modifiedAt: parsed.modifiedAt,
            permissions: parsed.permissions,
            linkTarget: parsed.linkTarget
        )
    }

    private func removeRemoteItem(_ item: FileItem) async throws {
        if item.kind == .directory {
            for child in try await list(item.path, showsHiddenFiles: true) {
                try await removeRemoteItem(child)
            }
            try await checked("rmdir \(quote(item.path))\n")
        } else {
            try await checked("rm \(quote(item.path))\n")
        }
    }

    private func runSFTP(_ commands: String, cancellation: CancellableProcess? = nil) async throws -> ProcessResult {
        guard let server else { throw RemoteFileError.noServer }
        var environment = ProcessInfo.processInfo.environment
        if let passwordScriptURL {
            environment["SSH_ASKPASS"] = passwordScriptURL.path
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment["DISPLAY"] = "inchspace:0"
        }
        if credential?.authentication == .password {
            try await ensurePasswordControlConnection(environment: environment)
        }

        var args = [
            "-q", "-b", "-",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=\(max(1, server.connectionTimeout))",
            "-o", "StrictHostKeyChecking=yes",
            "-o", OpenSSHProcess.configurationOption(
                "UserKnownHostsFile",
                value: Self.knownHostsURL.path
            ),
            "-o", "ControlMaster=auto",
            "-o", "ControlPersist=60",
            "-o", OpenSSHProcess.configurationOption(
                "ControlPath",
                value: Self.controlPath(for: server)
            ),
            "-P", String(server.port),
        ]
        if let credential, credential.authentication == .sshKey, !credential.keyPath.isEmpty {
            args += ["-i", credential.keyPath]
        }
        args.append("\(server.user)@\(server.host)")
        return try await OpenSSHProcess.run(executable: "/usr/bin/sftp", arguments: args, input: Data(commands.utf8), environment: environment, cancellation: cancellation)
    }

    /// `sftp -b` forces SSH batch mode and therefore cannot perform password
    /// authentication itself. Authenticate a control master first, then let
    /// batch SFTP reuse it so command failures still produce a nonzero status.
    private func ensurePasswordControlConnection(environment: [String: String]) async throws {
        guard let server else { throw RemoteFileError.noServer }
        let endpoint = "\(server.user)@\(server.host)"
        let controlPath = Self.controlPath(for: server)
        let check = try await OpenSSHProcess.run(
            executable: "/usr/bin/ssh",
            arguments: ["-S", controlPath, "-p", String(server.port), "-O", "check", endpoint]
        )
        if check.status == 0 { return }

        // A crashed process can leave a stale socket behind.
        if FileManager.default.fileExists(atPath: controlPath) {
            try? FileManager.default.removeItem(atPath: controlPath)
        }

        let result = try await OpenSSHProcess.run(
            executable: "/usr/bin/ssh",
            arguments: [
                "-M", "-N", "-f",
                "-S", controlPath,
                "-o", "BatchMode=no",
                "-o", "PubkeyAuthentication=no",
                "-o", "PreferredAuthentications=password,keyboard-interactive",
                "-o", "NumberOfPasswordPrompts=1",
                "-o", "ConnectTimeout=\(max(1, server.connectionTimeout))",
                "-o", "StrictHostKeyChecking=yes",
                "-o", OpenSSHProcess.configurationOption(
                    "UserKnownHostsFile",
                    value: Self.knownHostsURL.path
                ),
                "-p", String(server.port),
                endpoint,
            ],
            environment: environment
        )
        guard result.status == 0 else { throw classify(result.output) }
    }

    private func prepareCredential() throws {
        guard let server, let credential else { return }
        if credential.authentication == .password {
            let password = try RunnerServerCredentialStore.password(for: server.id)
            let url = FileManager.default.temporaryDirectory.appending(path: "inchspace-sftp-askpass-\(UUID().uuidString)")
            let escaped = password.replacingOccurrences(of: "'", with: "'\\''")
            try Data("#!/bin/sh\nprintf '%s\\n' '\(escaped)'\n".utf8).write(to: url, options: [.atomic, .completeFileProtection])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            passwordScriptURL = url
        } else if credential.authentication == .sshKey, let bookmark = credential.keyBookmark {
            let url = try SecurityScopedBookmarkService.resolve(bookmark)
            if url.startAccessingSecurityScopedResource() { securityScopedKeyURL = url }
        }
    }

    private func fingerprint(for keyLine: String) async throws -> String {
        let url = FileManager.default.temporaryDirectory.appending(path: "inchspace-host-key-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data((keyLine + "\n").utf8).write(to: url, options: .atomic)
        let result = try await OpenSSHProcess.run(executable: "/usr/bin/ssh-keygen", arguments: ["-lf", url.path, "-E", "sha256"])
        guard result.status == 0 else { throw RemoteFileError.processFailed("无法计算服务器指纹。") }
        return result.output.split(separator: " ").dropFirst().first.map(String.init) ?? "未知"
    }

    private func preferredKeyLine(_ lines: [String]) -> String? {
        lines.first { $0.contains("ssh-ed25519") } ?? lines.first { $0.contains("ecdsa-") } ?? lines.first
    }

    private func classify(_ output: String) -> RemoteFileError {
        let value = output.lowercased()
        if value.contains("permission denied") { return value.contains("publickey") || value.contains("password") ? .authenticationFailed : .permissionDenied }
        if value.contains("timed out") || value.contains("timeout") { return .timeout }
        if value.contains("host key verification failed") { return .processFailed("Host Key 校验失败，服务器身份可能已改变。") }
        if value.contains("connection refused") { return .processFailed("服务器拒绝连接。") }
        let line = output.split(separator: "\n").last(where: { !$0.isEmpty }).map(String.init) ?? "SFTP 操作失败。"
        return .processFailed(line)
    }

    static func parseListingLine(_ line: String, parent: String) -> FileItem? {
        // OpenSSH SFTP may print `?` instead of a numeric hard-link count.
        // Capture the date fields as well so the table can display them.
        guard let listingPattern,
              let match = listingPattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              match.numberOfRanges == 7,
              let p = Range(match.range(at: 1), in: line),
              let s = Range(match.range(at: 2), in: line),
              let month = Range(match.range(at: 3), in: line),
              let day = Range(match.range(at: 4), in: line),
              let timeOrYear = Range(match.range(at: 5), in: line),
              let n = Range(match.range(at: 6), in: line) else { return nil }
        let permissions = String(line[p])
        let size = Int64(line[s]) ?? 0
        var name = String(line[n])
        let kind: FileItemKind = permissions.first == "d" ? .directory : (permissions.first == "l" ? .symbolicLink : .file)
        var target: String?
        if kind == .symbolicLink, let range = name.range(of: " -> ") { target = String(name[range.upperBound...]); name = String(name[..<range.lowerBound]) }
        // `ls -l <directory>` commonly prefixes every result with that path.
        // A remote filename itself cannot contain '/', so retain only the last
        // component before joining it with the requested parent.
        if let slash = name.lastIndex(of: "/") {
            name = String(name[name.index(after: slash)...])
        }
        let path = parent == "/"
            ? "/\(name)"
            : "\(parent.hasSuffix("/") ? String(parent.dropLast()) : parent)/\(name)"
        return FileItem(
            name: name,
            path: path,
            kind: kind,
            size: size,
            modifiedAt: parseListingDate(
                month: String(line[month]),
                day: String(line[day]),
                timeOrYear: String(line[timeOrYear])
            ),
            permissions: permissions,
            linkTarget: target
        )
    }

    private static func parseListingDate(month: String, day: String, timeOrYear: String) -> Date? {
        if timeOrYear.contains(":") {
            let calendar = Calendar.current
            let year = calendar.component(.year, from: Date())
            guard var date = recentListingDateFormatter.date(from: "\(year) \(month) \(day) \(timeOrYear)") else { return nil }
            // `ls` uses a time instead of a year for recent entries. Around New
            // Year, an entry from December can otherwise appear in the future.
            if date.timeIntervalSinceNow > 86_400,
               let previousYear = calendar.date(byAdding: .year, value: -1, to: date) {
                date = previousYear
            }
            return date
        }
        return historicalListingDateFormatter.date(from: "\(month) \(day) \(timeOrYear)")
    }

    private func quote(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
    private func join(_ parent: String, _ child: String) -> String { parent == "/" ? "/\(child)" : "\(parent.hasSuffix("/") ? String(parent.dropLast()) : parent)/\(child)" }
    private func parent(of path: String) -> String { (path as NSString).deletingLastPathComponent.isEmpty ? "/" : (path as NSString).deletingLastPathComponent }
}
