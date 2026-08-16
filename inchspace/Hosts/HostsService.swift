import Foundation

nonisolated struct HostsService: Sendable {
    private let parser = HostsParser()
    private let hostsURL = URL(fileURLWithPath: "/private/etc/hosts")
    private let maximumBytes = 2 * 1_024 * 1_024

    static var backupDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "inchspace/Hosts/Backups", directoryHint: .isDirectory)
    }

    func load() throws -> HostsDocument {
        let data = try Data(contentsOf: hostsURL)
        guard data.count <= maximumBytes else { throw HostsError.fileTooLarge }
        guard let source = String(data: data, encoding: .utf8), !source.contains("\0") else { throw HostsError.invalidContent }
        return parser.parse(source)
    }

    func add(address: String, hostnames: [String], comment: String, to document: inout HostsDocument) throws {
        try parser.validate(address: address, hostnames: hostnames)
        if !document.lines.isEmpty, document.lines.last?.raw.isEmpty == false { document.lines.append(HostsLine(id: UUID(), raw: "", entry: nil)) }
        let id = UUID(); let index = document.lines.count
        let entry = HostEntry(id: id, address: address, hostnames: hostnames, comment: comment, enabled: true, isSystem: false, lineIndex: index)
        document.lines.append(HostsLine(id: id, raw: parser.line(address: address, hostnames: hostnames, comment: comment, enabled: true), entry: entry))
        document.endsWithNewline = true
    }

    func update(_ entry: HostEntry, address: String, hostnames: [String], comment: String, in document: inout HostsDocument) throws {
        try parser.validate(address: address, hostnames: hostnames)
        guard let index = document.lines.firstIndex(where: { $0.id == entry.id }) else { throw HostsError.entryNotFound }
        var updated = entry; updated.address = address; updated.hostnames = hostnames; updated.comment = comment; updated.lineIndex = index
        document.lines[index].entry = updated
        document.lines[index].raw = parser.line(address: address, hostnames: hostnames, comment: comment, enabled: updated.enabled)
    }

    func setEnabled(_ enabled: Bool, for entry: HostEntry, in document: inout HostsDocument) throws {
        guard !entry.isSystem else { throw HostsError.protectedSystemEntry }
        guard let index = document.lines.firstIndex(where: { $0.id == entry.id }) else { throw HostsError.entryNotFound }
        var updated = entry; updated.enabled = enabled; updated.lineIndex = index
        document.lines[index].entry = updated
        document.lines[index].raw = parser.line(address: updated.address, hostnames: updated.hostnames, comment: updated.comment, enabled: enabled)
    }

    func delete(_ entry: HostEntry, from document: inout HostsDocument) throws {
        guard !entry.isSystem else { throw HostsError.protectedSystemEntry }
        guard let index = document.lines.firstIndex(where: { $0.id == entry.id }) else { throw HostsError.entryNotFound }
        document.lines.remove(at: index)
        reindex(&document)
    }

    func save(_ document: HostsDocument) throws {
        let content = document.rendered
        try validateGenerated(content)
        _ = try backupCurrent()
        let stagingDirectory = FileManager.default.temporaryDirectory.appending(path: "inchspace-hosts-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }
        let staged = stagingDirectory.appending(path: "hosts")
        try Data(content.utf8).write(to: staged, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: staged.path)
        let result = installWithAdministratorPrivileges(staged)
        guard result.status == 0 else {
            if result.output.lowercased().contains("user canceled") || result.output.contains("-128") { throw HostsError.authorizationCancelled }
            throw HostsError.writeFailed(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    @discardableResult func backupCurrent() throws -> URL {
        try FileManager.default.createDirectory(at: Self.backupDirectory, withIntermediateDirectories: true)
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd-HHmmss-SSS"
        let target = Self.backupDirectory.appending(path: "hosts-\(formatter.string(from: Date())).backup")
        try FileManager.default.copyItem(at: hostsURL, to: target)
        try pruneBackups()
        return target
    }

    func backups() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: Self.backupDirectory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: Self.backupDirectory, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension == "backup" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    func restore(_ backup: URL) throws {
        let allowed = try backups().contains { $0.standardizedFileURL == backup.standardizedFileURL }
        guard allowed else { throw HostsError.backupNotFound }
        let data = try Data(contentsOf: backup); guard let content = String(data: data, encoding: .utf8) else { throw HostsError.invalidContent }
        try save(parser.parse(content))
    }

    func flushDNS() -> Bool {
        let result = run("/usr/bin/dscacheutil", ["-flushcache"])
        return result.status == 0
    }

    private func validateGenerated(_ content: String) throws {
        guard content.utf8.count <= maximumBytes, !content.contains("\0") else { throw HostsError.invalidContent }
        for line in parser.parse(content).entries { try parser.validate(address: line.address, hostnames: line.hostnames) }
    }

    private func reindex(_ document: inout HostsDocument) {
        for index in document.lines.indices { document.lines[index].entry?.lineIndex = index }
    }

    private func pruneBackups() throws {
        for url in try backups().dropFirst(10) { try FileManager.default.removeItem(at: url) }
    }

    private func installWithAdministratorPrivileges(_ staged: URL) -> (status: Int32, output: String) {
        // The script is constant and receives only an app-created temporary path. Hosts content
        // never enters AppleScript or a shell command, and the destination cannot be supplied by UI.
        let script = """
        on run argv
            set sourcePath to item 1 of argv
            do shell script ("/usr/bin/install -o root -g wheel -m 0644 " & quoted form of sourcePath & " /private/etc/hosts") with administrator privileges
        end run
        """
        return run("/usr/bin/osascript", ["-e", script, staged.path])
    }

    private func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process(); let pipe = Pipe(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments; process.standardOutput = pipe; process.standardError = pipe
        do { try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit(); return (process.terminationStatus, String(decoding: data, as: UTF8.self)) }
        catch { return (-1, error.localizedDescription) }
    }
}
