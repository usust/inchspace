import Foundation

/// Per-file results and the bookkeeping that keeps them attached to files as files and folders move.
extension ArchiveService {
    /// Saves final decisions for files that stay where they are. Moved files are recorded by `applyAI`.
    func saveFileRecords(_ records: [ArchiveFileRecord]) throws {
        guard !records.isEmpty else { return }
        var next = state
        var files = next.files ?? [:]
        for record in records { files[record.path] = record }
        next.files = files
        try commit(next)
    }

    /// Keeps a file's result with it when the user moves it back by undoing a batch. Where the user put a
    /// file back is where it belongs, so the record becomes organized there.
    func moveRecords(from source: String, to destination: String) throws {
        var next = state
        Self.rekey(&next, from: source, to: destination)
        if var record = next.files?[destination] {
            record.resolution = .organized
            record.stage = .grouped
            record.misplaced = nil
            next.files?[destination] = record
        }
        try commit(next)
    }

    /// Stamps files that were left unresolved during this run with the folder layout as it is now, so they are
    /// skipped until the layout or the workspace changes.
    func stampUnresolved(since start: Date) throws {
        try withAccess(state.configuration) { config in
            let (directories, _) = try ArchiveDirectoryFileSystem.inventory(config)
            let structure = ArchiveDirectoryFileSystem.signature(directories)
            var next = state
            guard var files = next.files else { return }
            for (path, record) in files where !record.isResolved && (record.structure == nil || record.processedAt >= start) {
                files[path]?.structure = structure
            }
            next.files = files
            try commit(next)
        }
    }

    /// The current folder layout digest, compared with the last audit's to decide whether the structure needs
    /// another look.
    func structureSignature() throws -> String {
        try withAccess(state.configuration) { config in
            ArchiveDirectoryFileSystem.signature(try ArchiveDirectoryFileSystem.inventory(config).0)
        }
    }

    func saveFolderRecords(_ records: [ArchiveFolderRecord]) throws {
        guard !records.isEmpty else { return }
        var next = state
        var folders = next.folders ?? [:]
        for record in records { folders[record.path] = record }
        next.folders = folders
        try commit(next)
    }

    /// Replaces every folder record inside `root` with `records`; folders that are gone lose theirs.
    func replaceFolderRecords(_ records: [ArchiveFolderRecord], inside root: String) throws {
        var next = state
        var folders = (next.folders ?? [:]).filter { $0.key != root && !$0.key.hasPrefix(root + "/") }
        for record in records { folders[record.path] = record }
        next.folders = folders
        try commit(next)
    }

    func saveAudit(_ audit: ArchiveAuditState?) throws {
        var next = state
        next.audit = audit
        try commit(next)
    }

    func saveConsistency(_ report: ArchiveConsistencyReport) throws {
        var next = state
        next.consistency = report
        try commit(next)
    }

    /// A new preference changes the convention, so the next run audits the whole structure again.
    func setPreference(_ preference: String?) throws {
        var next = state
        let text = preference?.trimmingCharacters(in: .whitespacesAndNewlines)
        next.preference = text?.isEmpty == false ? String(text!.prefix(2_000)) : nil
        next.audit = nil
        try commit(next)
    }

    /// A context for any files in the workspace, with or without records. Unchanged files reuse their recorded
    /// hash; others are hashed. Used for moves that are not about a single file's review, such as merging folders.
    func prepareContext(paths: [String], now: Date = Date()) throws -> ArchiveAIContext {
        try withAccess(state.configuration) { config in
            try ArchiveFileSystem.validateConfiguration(config, stateDirectory: persistence.directory)
            let (directories, warnings) = try ArchiveDirectoryFileSystem.inventory(config)
            var files: [ArchiveAIFile] = []
            for path in paths {
                try Task.checkCancellation()
                let url = URL(fileURLWithPath: path)
                guard let root = config.folders.first(where: { $0.role != .excluded && ArchiveFileSystem.contains(url, in: $0.url) }),
                      let quick = try? ArchiveFileSystem.quickFingerprint(url) else { continue }
                let fingerprint: ArchiveFingerprint
                if let known = state.files?[path]?.fingerprint, known.sameMetadata(quick), !known.sha256.isEmpty {
                    fingerprint = known
                } else if let hashed = try? ArchiveFileSystem.fingerprint(url) {
                    fingerprint = hashed
                } else { continue }
                files.append(ArchiveAIFile(id: UUID().uuidString, rootID: root.id.uuidString,
                                           relativePath: ArchiveDirectoryFileSystem.relativePath(url, root: root.url),
                                           source: url, fingerprint: fingerprint, keywords: []))
            }
            let context = ArchiveAIContext(version: state.version, createdAt: now, folders: config.folders,
                                           directories: directories, files: files, warnings: warnings,
                                           structure: ArchiveDirectoryFileSystem.signature(directories))
            aiContext = context
            aiPreview = nil
            return context
        }
    }

    /// A context for files that already have a record, for grouping them after review. Files that are gone or
    /// changed since their record lose it, so the next run reviews them again.
    func prepareRecordedContext(paths: [String], now: Date = Date()) throws -> ArchiveAIContext {
        try withAccess(state.configuration) { config in
            try ArchiveFileSystem.validateConfiguration(config, stateDirectory: persistence.directory)
            let (directories, warnings) = try ArchiveDirectoryFileSystem.inventory(config)
            var next = state
            var files: [ArchiveAIFile] = []
            for path in paths {
                try Task.checkCancellation()
                guard let record = next.files?[path] else { continue }
                let url = URL(fileURLWithPath: path)
                guard let root = config.folders.first(where: { $0.role != .excluded && ArchiveFileSystem.contains(url, in: $0.url) }),
                      let quick = try? ArchiveFileSystem.quickFingerprint(url), record.fingerprint.sameMetadata(quick) else {
                    next.files?.removeValue(forKey: path)
                    continue
                }
                files.append(ArchiveAIFile(id: UUID().uuidString, rootID: root.id.uuidString,
                                           relativePath: ArchiveDirectoryFileSystem.relativePath(url, root: root.url),
                                           source: url, fingerprint: record.fingerprint, keywords: []))
            }
            try commit(next)
            let context = ArchiveAIContext(version: state.version, createdAt: now, folders: config.folders,
                                           directories: directories, files: files, warnings: warnings,
                                           structure: ArchiveDirectoryFileSystem.signature(directories))
            aiContext = context
            aiPreview = nil
            return context
        }
    }

    /// A context for one scanned file, taken just before that file is reviewed, so each file is planned and
    /// applied against a fresh snapshot of the folders. Keywords are passed in from the scan, because applying
    /// the previous file's change clears the keyword cache.
    func prepareFileContext(path: String, fingerprint expected: ArchiveFingerprint, keywords: [String],
                            now: Date = Date()) throws -> ArchiveAIContext {
        try withAccess(state.configuration) { config in
            try ArchiveFileSystem.validateConfiguration(config, stateDirectory: persistence.directory)
            let (directories, warnings) = try ArchiveDirectoryFileSystem.inventory(config)
            let url = URL(fileURLWithPath: path)
            var files: [ArchiveAIFile] = []
            // Metadata is enough here; the hash taken during the scan is checked again right before any move.
            if let root = config.folders.first(where: { $0.role != .excluded && ArchiveFileSystem.contains(url, in: $0.url) }),
               let quick = try? ArchiveFileSystem.quickFingerprint(url), expected.sameMetadata(quick) {
                files.append(ArchiveAIFile(id: UUID().uuidString, rootID: root.id.uuidString,
                                           relativePath: ArchiveDirectoryFileSystem.relativePath(url, root: root.url),
                                           source: url, fingerprint: expected, keywords: keywords))
            }
            let context = ArchiveAIContext(version: state.version, createdAt: now, folders: config.folders,
                                           directories: directories, files: files, warnings: warnings,
                                           structure: ArchiveDirectoryFileSystem.signature(directories))
            aiContext = context
            aiPreview = nil
            return context
        }
    }

    /// Re-points everything remembered about a path, or about every path inside a moved folder.
    nonisolated static func rekey(_ state: inout ArchiveState, from: String, to: String) {
        guard from != to else { return }
        func moved(_ path: String) -> String? {
            if path == from { return to }
            return path.hasPrefix(from + "/") ? to + path.dropFirst(from.count) : nil
        }
        func remap<Value>(_ values: [String: Value], update: (inout Value, String) -> Void = { _, _ in }) -> [String: Value] {
            var result: [String: Value] = [:]
            for (path, value) in values {
                guard let target = moved(path) else {
                    if result[path] == nil { result[path] = value }
                    continue
                }
                var value = value
                update(&value, target)
                result[target] = value
            }
            return result
        }
        state.files = state.files.map { remap($0) { $0.path = $1 } }
        state.folders = state.folders.map { remap($0) { $0.path = $1 } }
        state.settled = state.settled.map { remap($0) }
        state.cache = remap(state.cache) { $0.url = URL(fileURLWithPath: $1) }
        state.observations = remap(state.observations)
    }
}
