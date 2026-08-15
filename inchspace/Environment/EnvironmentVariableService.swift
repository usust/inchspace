import Foundation

nonisolated final class EnvironmentVariableService {
    static let managedStartMarker = "# >>> inchspace Environment Variables >>>"
    static let managedEndMarker = "# <<< inchspace Environment Variables <<<"
    static let supportedFileNames = [".profile", ".bash_profile", ".bashrc", ".zprofile", ".zshrc"]

    let homeDirectory: URL
    private let fileManager: FileManager
    private let processEnvironment: [String: String]
    private let updatesEnvironmentStore: Bool
    private(set) var scanIssues: [EnvironmentScanIssue] = []

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        updatesEnvironmentStore: Bool = true
    ) {
        self.homeDirectory = homeDirectory
        self.fileManager = fileManager
        self.processEnvironment = processEnvironment
        self.updatesEnvironmentStore = updatesEnvironmentStore
    }

    static func isValidVariableName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first,
              CharacterSet.letters.union(CharacterSet(charactersIn: "_")).contains(first) else { return false }
        return name.unicodeScalars.dropFirst().allSatisfy {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).contains($0)
        }
    }

    func listEnvironmentVariables() -> [EnvironmentVariable] {
        scanIssues = []
        var grouped: [String: [EnvironmentVariableSource]] = [:]
        for (name, value) in processEnvironment {
            grouped[name, default: []].append(EnvironmentVariableSource(
                fileURL: nil,
                displayName: "当前 App",
                value: value,
                isProcessEnvironment: true
            ))
        }

        var inherited = processEnvironment
        for url in shellConfigURLs {
            guard fileManager.fileExists(atPath: url.path) else { continue }
            let content: String
            do {
                content = try read(url)
            } catch {
                scanIssues.append(EnvironmentScanIssue(fileURL: url, message: error.localizedDescription))
                continue
            }
            let parsed = ShellEnvironmentParser.parse(content, inheritedEnvironment: inherited)
            for definition in parsed.definitions {
                let source = EnvironmentVariableSource(
                    fileURL: url,
                    displayName: "~/\(url.lastPathComponent)",
                    value: definition.value,
                    line: definition.assignmentLineIndex + 1,
                    isManaged: definition.isManaged,
                    isEnabled: definition.isEnabled,
                    isExportedToPath: definition.isExportedToPath
                )
                grouped[definition.name, default: []].append(source)
                if definition.isEnabled { inherited[definition.name] = definition.value }
            }
            for definition in parsed.definitions where definition.isEnabled && definition.isExportedToPath {
                inherited["PATH"] = prependingPath(definition.value, to: inherited["PATH"] ?? "")
            }
        }

        let values = grouped.map { name, sources -> EnvironmentVariable in
            let effective = name == "PATH" ? (inherited["PATH"] ?? "")
                : sources.last(where: { !$0.isProcessEnvironment && $0.isEnabled })?.value
                ?? sources.last(where: \.isProcessEnvironment)?.value
                ?? sources.last?.value ?? ""
            let isPath = name == "PATH"
            let hasActiveSource = sources.contains { $0.isProcessEnvironment || $0.isEnabled }
            return EnvironmentVariable(
                name: name,
                effectiveValue: effective,
                sources: sources,
                managedByApp: sources.contains(where: \.isManaged),
                variableType: isPath ? .path : .normal,
                status: hasActiveSource ? status(for: effective, isPath: isPath) : .disabled
            )
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        if updatesEnvironmentStore {
            let activeValues = values.filter { variable in
                variable.sources.contains { $0.isProcessEnvironment || $0.isEnabled }
            }
            var environment = Dictionary(uniqueKeysWithValues: activeValues.map { ($0.name, $0.effectiveValue) })
            if let path = inherited["PATH"] { environment["PATH"] = path }
            AppEnvironmentStore.shared.replaceOverrides(with: environment)
        }
        return values
    }

    func getEnvironmentVariable(_ name: String) -> EnvironmentVariable? {
        listEnvironmentVariables().first { $0.name == name }
    }

    @discardableResult
    func createEnvironmentVariable(
        name: String,
        value: String,
        destination: URL? = nil,
        exportToPath: Bool = false
    ) throws -> EnvironmentVariable {
        try updateEnvironmentVariable(name: name, value: value, destination: destination, exportToPath: exportToPath)
    }

    @discardableResult
    func updateEnvironmentVariable(
        name: String,
        value: String,
        destination: URL? = nil,
        exportToPath: Bool? = nil
    ) throws -> EnvironmentVariable {
        guard Self.isValidVariableName(name) else { throw EnvironmentServiceError.invalidVariableName }
        let existing = getEnvironmentVariable(name)
        let existingSource = existing?.sources.last(where: { !$0.isProcessEnvironment && $0.isEnabled })
        let requestedTarget = destination ?? existingSource?.fileURL ?? homeDirectory.appending(path: ".zprofile")
        let target = try validatedWritableURL(requestedTarget)
        let content = try readIfPresent(target)
        let parsed = ShellEnvironmentParser.parse(content, inheritedEnvironment: processEnvironment)
        var lines = parsed.lines
        let matches = parsed.definitions.filter { $0.name == name && $0.isEnabled }
        let keepsPathExport = name != "PATH"
            && (exportToPath ?? parsed.definitions.contains { $0.name == name && $0.isExportedToPath })
        if parsed.definitions.contains(where: { $0.name == name && !$0.isEnabled }), matches.isEmpty {
            throw EnvironmentServiceError.disabledSource
        }

        if let first = matches.first {
            lines[first.assignmentLineIndex] = "export \(name)=\(ShellEnvironmentParser.escapeValue(value))"
            for duplicate in matches.dropFirst().sorted(by: { $0.assignmentLineIndex > $1.assignmentLineIndex }) {
                lines.remove(at: duplicate.assignmentLineIndex)
            }
        } else {
            lines = updatingManagedBlock(in: lines, name: name, value: value)
        }
        lines = updatingPathExport(in: lines, name: name, enabled: keepsPathExport)

        try write(lines.joined(separator: parsed.newline), to: target)
        if updatesEnvironmentStore { AppEnvironmentStore.shared.restore(name) }
        guard let variable = getEnvironmentVariable(name) else { throw EnvironmentServiceError.invalidConfiguration(target) }
        return variable
    }

    func deleteEnvironmentVariable(name: String, from sourceURLs: [URL]? = nil) throws {
        let variable = getEnvironmentVariable(name)
        let urls = sourceURLs ?? variable?.sources.compactMap(\.fileURL) ?? []
        guard !urls.isEmpty else { throw EnvironmentServiceError.sourceNotFound }
        for requestedURL in Array(Set(urls)) {
            let url = try validatedWritableURL(requestedURL)
            let content = try read(url)
            let parsed = ShellEnvironmentParser.parse(content, inheritedEnvironment: processEnvironment)
            let matches = parsed.definitions.filter { $0.name == name }
            guard !matches.isEmpty else { continue }
            var lines = parsed.lines
            let removedIndexes = Set(matches.map(\.assignmentLineIndex))
            for definition in matches {
                if let exportIndex = definition.exportLineIndex {
                    lines[exportIndex] = removingName(name, fromStandaloneExport: lines[exportIndex])
                }
            }
            for index in removedIndexes.sorted(by: >) { lines.remove(at: index) }
            lines = updatingPathExport(in: lines, name: name, enabled: false)
            lines = removingEmptyManagedBlock(from: lines)
            try write(lines.joined(separator: parsed.newline), to: url)
        }
        _ = listEnvironmentVariables()
    }

    func disableEnvironmentVariable(name: String, in requestedURL: URL) throws {
        let url = try validatedWritableURL(requestedURL)
        let content = try read(url)
        let parsed = ShellEnvironmentParser.parse(content, inheritedEnvironment: processEnvironment)
        let matches = parsed.definitions.filter { $0.name == name && $0.isEnabled }
        guard !matches.isEmpty else { throw EnvironmentServiceError.sourceNotFound }
        var lines = parsed.lines
        for definition in matches {
            lines[definition.assignmentLineIndex] = ShellEnvironmentParser.disabledPrefix + lines[definition.assignmentLineIndex]
            if let exportIndex = definition.exportLineIndex {
                lines[exportIndex] = removingName(name, fromStandaloneExport: lines[exportIndex])
            }
        }
        if matches.contains(where: \.isExportedToPath) {
            lines = updatingPathExport(in: lines, name: name, enabled: false, remembersDisabledState: true)
        }
        try write(lines.joined(separator: parsed.newline), to: url)
        _ = reloadEnvironment()
    }

    func enableEnvironmentVariable(name: String, in requestedURL: URL) throws {
        let url = try validatedWritableURL(requestedURL)
        let content = try read(url)
        let parsed = ShellEnvironmentParser.parse(content, inheritedEnvironment: processEnvironment)
        let matches = parsed.definitions.filter { $0.name == name && !$0.isEnabled }
        guard !matches.isEmpty else { throw EnvironmentServiceError.sourceNotFound }
        var lines = parsed.lines
        for definition in matches {
            lines[definition.assignmentLineIndex] = restoringDisabledLine(lines[definition.assignmentLineIndex])
        }
        if matches.contains(where: \.isExportedToPath) {
            lines = updatingPathExport(in: lines, name: name, enabled: true)
        }
        try write(lines.joined(separator: parsed.newline), to: url)
        if updatesEnvironmentStore { AppEnvironmentStore.shared.restore(name) }
        _ = reloadEnvironment()
    }

    @discardableResult
    func reloadEnvironment() -> [EnvironmentVariable] {
        listEnvironmentVariables()
    }

    func listPathEntries() -> [EnvironmentPathEntry] {
        let value = getEnvironmentVariable("PATH")?.effectiveValue ?? processEnvironment["PATH"] ?? ""
        return pathEntries(from: value)
    }

    func pathEntries(from value: String) -> [EnvironmentPathEntry] {
        var seen = Set<String>()
        return value.split(separator: ":", omittingEmptySubsequences: true).compactMap { part in
            let path = String(part)
            let normalized = normalizePath(path)
            guard seen.insert(normalized).inserted else { return nil }
            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(atPath: expandedPath(path), isDirectory: &isDirectory) && isDirectory.boolValue
            return EnvironmentPathEntry(path: path, exists: exists)
        }
    }

    func addPathEntry(_ path: String, to entries: [EnvironmentPathEntry]) throws -> [EnvironmentPathEntry] {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return entries }
        let normalized = normalizePath(trimmed)
        guard !entries.contains(where: { normalizePath($0.path) == normalized }) else {
            throw EnvironmentServiceError.duplicatePath
        }
        var result = entries
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: expandedPath(trimmed), isDirectory: &isDirectory) && isDirectory.boolValue
        result.append(EnvironmentPathEntry(path: trimmed, exists: exists))
        return result
    }

    func savePathEntries(_ entries: [EnvironmentPathEntry], destination: URL? = nil) throws {
        var seen = Set<String>()
        let paths = entries.map(\.path).filter { seen.insert(normalizePath($0)).inserted }
        _ = try updateEnvironmentVariable(name: "PATH", value: paths.joined(separator: ":"), destination: destination)
    }

    var shellConfigURLs: [URL] {
        Self.supportedFileNames.map { homeDirectory.appending(path: $0) }
    }

    private func read(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        guard let value = String(data: data, encoding: .utf8) else {
            throw EnvironmentServiceError.unsupportedEncoding(url)
        }
        return value
    }

    private func readIfPresent(_ url: URL) throws -> String {
        fileManager.fileExists(atPath: url.path) ? try read(url) : ""
    }

    private func write(_ content: String, to url: URL) throws {
        let data = Data(content.utf8)
        let validationURL = fileManager.temporaryDirectory.appending(path: "inchspace-env-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: validationURL) }
        try data.write(to: validationURL, options: .atomic)
        guard let validated = try? read(validationURL), validated == content else {
            throw EnvironmentServiceError.invalidConfiguration(url)
        }
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private func updatingManagedBlock(in originalLines: [String], name: String, value: String) -> [String] {
        var lines = originalLines
        if lines.count == 1, lines[0].isEmpty { lines = [] }
        let line = "export \(name)=\(ShellEnvironmentParser.escapeValue(value))"
        if let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == Self.managedStartMarker }),
           let end = lines[(start + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == Self.managedEndMarker }) {
            lines.insert(line, at: end)
        } else {
            if let last = lines.last, !last.isEmpty { lines.append("") }
            lines += [Self.managedStartMarker, line, Self.managedEndMarker, ""]
        }
        return lines
    }

    private func removingEmptyManagedBlock(from originalLines: [String]) -> [String] {
        var lines = originalLines
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == Self.managedStartMarker }),
              let end = lines[(start + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == Self.managedEndMarker }) else { return lines }
        let body = lines[(start + 1)..<end].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if body.isEmpty { lines.removeSubrange(start...end) }
        return lines
    }

    private func status(for value: String, isPath: Bool) -> EnvironmentVariableStatus {
        guard !value.isEmpty else { return .unavailable }
        if isPath { return .valid }
        guard value.hasPrefix("/") || value.hasPrefix("~/") else { return .valid }
        var directory: ObjCBool = false
        return fileManager.fileExists(atPath: expandedPath(value), isDirectory: &directory) && directory.boolValue
            ? .valid : .missingDirectory
    }

    private func expandedPath(_ path: String) -> String {
        if path == "~" { return homeDirectory.path }
        if path.hasPrefix("~/") { return homeDirectory.path + String(path.dropFirst()) }
        return path
    }

    private func normalizePath(_ path: String) -> String {
        var value = expandedPath(path).trimmingCharacters(in: .whitespacesAndNewlines)
        while value.count > 1, value.hasSuffix("/") { value.removeLast() }
        return URL(fileURLWithPath: value).standardizedFileURL.path
    }

    private func prependingPath(_ entry: String, to path: String) -> String {
        let normalized = normalizePath(entry)
        let existing = path.split(separator: ":", omittingEmptySubsequences: true).map(String.init)
        guard !existing.contains(where: { normalizePath($0) == normalized }) else { return path }
        return path.isEmpty ? entry : "\(entry):\(path)"
    }

    private func updatingPathExport(
        in originalLines: [String],
        name: String,
        enabled: Bool,
        remembersDisabledState: Bool = false
    ) -> [String] {
        var lines = removingPathExport(from: originalLines, name: name)
        if remembersDisabledState {
            if let last = lines.last, !last.isEmpty { lines.append("") }
            lines.append(ShellEnvironmentParser.disabledPathPrefix + name)
            return lines
        }
        guard enabled else { return lines }
        if let last = lines.last, !last.isEmpty { lines.append("") }
        lines += pathExportBlock(name: name)
        return lines
    }

    private func removingPathExport(from originalLines: [String], name: String) -> [String] {
        var lines = originalLines
        let startMarker = "\(ShellEnvironmentParser.pathStartPrefix)\(name)\(ShellEnvironmentParser.pathStartSuffix)"
        let endMarker = "# <<< inchspace PATH: \(name) <<<"
        while let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == startMarker }) {
            if let end = lines[start...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == endMarker }) {
                lines.removeSubrange(start...end)
            } else {
                lines.remove(at: start)
            }
        }
        let disabledMarker = ShellEnvironmentParser.disabledPathPrefix + name
        lines.removeAll { $0.trimmingCharacters(in: .whitespaces) == disabledMarker }
        while lines.count > 1, lines.last?.isEmpty == true, lines.dropLast().last?.isEmpty == true { lines.removeLast() }
        return lines
    }

    private func pathExportBlock(name: String) -> [String] {
        [
            "\(ShellEnvironmentParser.pathStartPrefix)\(name)\(ShellEnvironmentParser.pathStartSuffix)",
            "if [ -n \"${\(name):-}\" ]; then",
            "    case \":${PATH:-}:\" in",
            "        *\":${\(name)}:\"*) ;;",
            "        *) export PATH=\"${\(name)}${PATH:+:${PATH}}\" ;;",
            "    esac",
            "fi",
            "# <<< inchspace PATH: \(name) <<<",
            "",
        ]
    }

    private func validatedWritableURL(_ requestedURL: URL) throws -> URL {
        let requested = requestedURL.standardizedFileURL
        let allowed = Set(shellConfigURLs.map { $0.standardizedFileURL.path })
        guard allowed.contains(requested.path) else { throw EnvironmentServiceError.unsafeConfiguration(requestedURL) }
        guard fileManager.fileExists(atPath: requested.path) else { return requested }
        let resolved = requested.resolvingSymlinksInPath().standardizedFileURL
        let resolvedHome = homeDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved.path == resolvedHome || resolved.path.hasPrefix(resolvedHome + "/") else {
            throw EnvironmentServiceError.unsafeConfiguration(requestedURL)
        }
        return resolved
    }

    private func restoringDisabledLine(_ line: String) -> String {
        guard let range = line.range(of: ShellEnvironmentParser.disabledPrefix) else { return line }
        let original = String(line[range.upperBound...])
        let trimmed = original.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("export ") || trimmed.hasPrefix("export\t") ? original : "export \(trimmed)"
    }

    private func removingName(_ name: String, fromStandaloneExport line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("export ") || trimmed.hasPrefix("export\t"), !trimmed.contains("=") else { return line }
        let names = trimmed.dropFirst(6).split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            .filter { $0 != name }
        return names.isEmpty ? "" : "export \(names.joined(separator: " "))"
    }
}
