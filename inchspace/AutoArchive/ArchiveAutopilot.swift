import Foundation

nonisolated struct ArchiveRunSummary: Equatable, Sendable {
    var movedFiles = 0
    var renamedFiles = 0
    var createdDirectories = 0
    var movedDirectories = 0
    var removedDirectories = 0
    var leftUntouched = 0
    var batchIDs: [UUID] = []
    /// True when the round limit stopped the run before the folder was fully reviewed.
    var hasMore = false
    /// Why the structure audit could not ask the model, when it could not.
    var auditFailure: String?
    /// The local consistency check at the end of the run.
    var consistency: ArchiveConsistencyReport?

    var isEmpty: Bool {
        movedFiles == 0 && renamedFiles == 0 && createdDirectories == 0 && movedDirectories == 0 && removedDirectories == 0
    }
}

nonisolated struct ArchiveNeedsReview: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// What the run is doing right now and how far along it is, for a progress display.
nonisolated struct ArchiveRunProgress: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case scanning
        /// Stage 0: checking every folder against the convention.
        case auditing
        /// Stage 1: merging, renaming and splitting folders to follow the convention.
        case restructuring
        /// New files must hold still briefly before they are touched.
        case waitingForStableFiles
        /// Stage 2: reviewing one file's place, name and topic.
        case reviewing
        /// Stage 3: putting related files of one folder into subfolders.
        case grouping
        /// Stage 4: grouping related folders under a new level.
        case nesting
        case applying
        /// After the run: the local consistency check.
        case checking
    }

    var phase: Phase = .scanning
    /// The folder being grouped or nested, as shown to the user.
    var directory = ""
    var round = 0
    /// Files offered to the planner in the current round.
    var batchFiles = 0
    /// Files already reviewed in this run (moved or deliberately left in place).
    var processedFiles = 0
    /// Files still ahead, including the current batch. Zero while unknown.
    var remainingFiles = 0
    /// Characters of the model's answer received so far in the current round.
    var receivedCharacters = 0

    var totalFiles: Int { processedFiles + remainingFiles }
    /// 0...1 when the folder size is known, nil while scanning the first time.
    var fraction: Double? {
        guard totalFiles > 0 else { return nil }
        return min(1, Double(processedFiles) / Double(totalFiles))
    }
}

/// Where one file stands in the current run, for a per-file list next to the progress bar.
nonisolated struct ArchiveFileActivity: Identifiable, Equatable, Sendable {
    enum Status: Equatable, Sendable {
        /// Dropped from a smaller retry batch; a later round picks it up again.
        case queued
        case processing
        /// The result is recorded: moved, or deliberately left in place.
        case completed
        /// Reviewed and recorded, but no clear destination yet; looked at again when the folders change.
        case unplaced
        /// No valid plan came back, so the file stays where it is.
        case skipped
        case failed
    }

    var id: String { path }
    var path: String
    var status: Status
    var detail: String?
    var updatedAt = Date()
    /// The saved result, once there is one, so the list can show what changed without another lookup.
    var record: ArchiveFileRecord? = nil
    var name: String { (path as NSString).lastPathComponent }
}

/// Runs the whole organize cycle without user decisions, under one convention (`ArchiveConvention`), in stages that
/// each finish before the next begins — the structure is settled first, then files are placed into it:
/// 0. audit every folder of the tree: which category or project it is, whether its name follows the convention and
///    whether it is pure (counted locally) — when the layout changed, or the last audit failed or left items open;
/// 1. put the structure right: every folder of a category merged into the category's canonical path, names that
///    break the rules replaced, files that do not belong in a mixed folder moved to their category, and file names
///    the last consistency check flagged corrected;
/// 2. review new or changed files in small batches — one question covers several files, but each answer is then
///    checked and applied one file at a time against a fresh snapshot: it may only go to an existing folder, and its
///    name is normalized to that folder's pattern (`ArchiveNameNormalizer`);
/// 3. put related files still left loose into new or existing folders whose names pass the convention;
/// 4. group related folders under new levels, bottom up, one level per pass.
/// A local consistency check closes the run; what it finds is handled first by the next run's audit.
/// Safety checks stay in `ArchiveService`; autopilot only sequences them and never bypasses them.
@MainActor
struct ArchiveAutopilot {
    typealias Progress = @MainActor (ArchiveRunProgress) -> Void

    let service: ArchiveService
    let planner: ArchiveStagePlanner
    var stableWait: Duration = .milliseconds(2_300)
    var maxRounds = 60
    var maxAttemptsPerRound = 2
    /// Files taken from each scan.
    var batchSize = 30
    /// Files asked about in one model request.
    var reviewBatch = 10
    var keywordLimit = 80
    /// Other files of the same folder shown per file.
    var siblingLimit = 20
    /// Similar folders from anywhere in the workspace offered per file (`ArchiveFolderCatalog`).
    var candidateLimit = 8
    /// Files of one folder shown to the planner at once when grouping.
    var groupingLimit = 60
    /// Folder levels one run may add inside a single folder.
    var maxNestingPasses = 2
    /// Grouping folders never pushes anything deeper than this below the workspace.
    var maxDepth = 4
    /// Pause after each model request; gives a local GPU a breather between batches.
    var cooldown: Duration = .zero
    /// Songs, videos, installers and very large files are put into their category's folder without asking
    /// the model (see `ArchiveFileKind`).
    var sortsByType = false
    /// Receives per-file status changes as the run moves through each batch.
    var report: @MainActor ([ArchiveFileActivity]) -> Void = { _ in }
    /// The convention in effect; `run` reads it from the saved preference before the first stage.
    private(set) var convention = ArchiveConvention.standard

    private var depthLimit: Int { min(maxDepth, convention.maxDepth) }
    private var unsortedFolder: String { convention.canonicalPath(ArchiveCategory.unsorted) }

    func run(progress: Progress = { _ in }) async throws -> ArchiveRunSummary {
        var configured = self
        configured.convention = await service.snapshot().convention
        return try await configured.runStages(progress: progress)
    }

    private func runStages(progress: Progress) async throws -> ArchiveRunSummary {
        var summary = ArchiveRunSummary()
        var status = ArchiveRunProgress()
        let start = Date()
        var audited = false
        do {
            if let audit = try await auditStructure(&status, progress) {
                audited = true
                summary.auditFailure = audit.failure
                try await normalizeStructure(audit, &summary, &status, progress)
                // Saved before the files are looked at, so a run stopped later does not redo stages 0 and 1.
                let previous = await service.snapshot().audit
                try await service.saveAudit(ArchiveAuditState(structure: try await service.structureSignature(),
                                                              status: audit.failure == nil ? .complete : .failed,
                                                              message: audit.failure, attempts: previous?.attempts ?? 0))
            }
            try await reviewFiles(since: start, &summary, &status, progress)
            // Grouping waits until every new file has been reviewed, so related files are seen together.
            if !summary.hasMore {
                let changed = try await groupFiles(&summary, &status, progress)
                try await nestFolders(changed, &summary, &status, progress)
            }
        } catch {
            // Stamp what this run did settle even when it stops early; otherwise every unresolved file would be
            // offered again first next time, and an interrupted run would keep circling the same files.
            try? await service.stampUnresolved(since: start)
            throw error
        }
        // Unresolved files are skipped until the layout differs from what they were last checked against.
        try await service.stampUnresolved(since: start)
        summary.consistency = try await checkConsistency(audited: audited, failure: summary.auditFailure, &status, progress)
        return summary
    }

    // MARK: Stage 0 – structure audit

    private struct StructureAudit {
        var verdicts: [ArchiveFolderVerdict]
        /// Why the model could not be asked; the dictionary's local verdicts were used alone.
        var failure: String?
    }

    /// Nil when the structure needs no audit this run.
    private func auditStructure(_ status: inout ArchiveRunProgress, _ progress: Progress) async throws -> StructureAudit? {
        try Task.checkCancellation()
        let structure = try await service.structureSignature()
        let snapshot = await service.snapshot()
        guard snapshot.needsAudit(structure: structure) else { return nil }
        let context = try await service.prepareContext(paths: [])
        guard let root = Self.workspace(context) else { return nil }
        let folders = Self.folders(in: context, root: root)
        status.phase = .auditing
        status.directory = root.url.lastPathComponent
        status.receivedCharacters = 0
        progress(status)
        let survey = ArchiveFolderSurvey.build(root: root.url, folders: folders, records: snapshot.files ?? [:], convention: convention)
        var answer: ArchiveAuditResponse?
        var failure: String?
        if ArchiveStructureAudit.needsModel(survey) {
            do {
                answer = try await planner.audit(ArchiveAuditRequest(survey: survey, convention: convention))
                try await rest()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Never recorded as done: the audit is retried next run, and the status strip says why it stopped.
                failure = error.localizedDescription
            }
        }
        return StructureAudit(verdicts: ArchiveStructureAudit.verdicts(survey, answer: answer, convention: convention), failure: failure)
    }

    // MARK: Stage 1 – structure to the convention

    private func normalizeStructure(_ audit: StructureAudit, _ summary: inout ArchiveRunSummary,
                                    _ status: inout ArchiveRunProgress, _ progress: Progress) async throws {
        guard let root = Self.workspace(try await service.prepareContext(paths: [])) else { return }
        status.phase = .restructuring
        progress(status)
        // Paths change as folders move; each verdict is followed to where its folder went.
        var verdicts = audit.verdicts
        func rebase(_ from: String, to: String) {
            for index in verdicts.indices where verdicts[index].path == from || verdicts[index].path.hasPrefix(from + "/") {
                verdicts[index].path = to + verdicts[index].path.dropFirst(from.count)
            }
        }
        func exists(_ relative: String) -> Bool { FileManager.default.fileExists(atPath: Self.url(relative, in: root).path) }

        // 1. One home per category: shallow folders first, so the main folder of a category is the one that moves
        //    to the canonical path and the others — nested ones included — are merged into it.
        let homes = verdicts.indices.filter { index in
            verdicts[index].category != nil && !ArchiveStructureAudit.isInsideProject(verdicts[index].path, convention: convention)
        }.sorted { (Self.depth(verdicts[$0].path), verdicts[$0].path) < (Self.depth(verdicts[$1].path), verdicts[$1].path) }
        for index in homes {
            try Task.checkCancellation()
            let current = verdicts[index]
            guard let category = current.category, exists(current.path) else { continue }
            let title = convention.canonicalName(category)
            if let home = canonicalFolder(category, root: root.url) {
                guard ArchiveFileSystem.nameKey(home) != ArchiveFileSystem.nameKey(current.path) else { continue }
                try await mergeFolder(current.path, into: home, depth: 0, reason: "「\(title)」只保留一个归宿", root: root, &summary, &status, progress)
                rebase(current.path, to: home)
            } else if try await moveFolder(current.path, to: convention.canonicalPath(category),
                                           reason: "「\(title)」类文件夹移到规范位置并使用规范名", &summary, &status, progress) {
                rebase(current.path, to: convention.canonicalPath(category))
            }
        }

        // 2. Names that break the convention, deepest first so a parent's rename does not move what is still ahead.
        let renames = verdicts.indices.filter { verdicts[$0].rename != nil }
            .sorted { Self.deeperLast(verdicts[$1].path, verdicts[$0].path) }
        for index in renames {
            try Task.checkCancellation()
            let current = verdicts[index]
            guard let name = current.rename, exists(current.path) else { continue }
            let parent = (current.path as NSString).deletingLastPathComponent
            let target = parent.isEmpty ? name : parent + "/" + name
            guard !exists(target) else { continue }
            if try await moveFolder(current.path, to: target, reason: "「\((current.path as NSString).lastPathComponent)」不符合目录规范，改为「\(name)」",
                                    &summary, &status, progress) {
                rebase(current.path, to: target)
            }
        }

        // 3. Mixed folders: the files that belong to another category go to that category's home.
        for verdict in verdicts where verdict.isMixed && exists(verdict.path) {
            let byCategory = Dictionary(grouping: verdict.strays.keys.sorted()) { verdict.strays[$0] ?? "" }
            for (category, names) in byCategory.sorted(by: { $0.key < $1.key }) where !category.isEmpty {
                let target = canonicalFolder(category, root: root.url) ?? convention.canonicalPath(category)
                guard target != verdict.path else { continue }
                let paths = names.map { Self.url(verdict.path, in: root).appendingPathComponent($0).path }
                    .filter { FileManager.default.fileExists(atPath: $0) }
                try await moveFiles(paths, into: target, root: root,
                                    reason: "「\(verdict.path)」混有\(convention.canonicalName(category))类文件，移到「\(target)」",
                                    title: "拆分混合文件夹「\(verdict.path)」", &summary, &status, progress)
            }
        }

        // 4. File names the last consistency check found off their folder's pattern.
        let flagged = (await service.snapshot().consistency?.issues ?? []).filter { $0.kind == .fileName }.map(\.path)
        for (folder, paths) in Dictionary(grouping: flagged, by: { ($0 as NSString).deletingLastPathComponent }).sorted(by: { $0.key < $1.key }) {
            let absolute = paths.map { Self.url($0, in: root).path }.filter { FileManager.default.fileExists(atPath: $0) }
            try await moveFiles(absolute, into: folder, root: root, reason: "按「\(folder.isEmpty ? "根目录" : folder)」的命名模式改名",
                                title: "规范「\(folder.isEmpty ? root.url.lastPathComponent : folder)」中的文件名", &summary, &status, progress)
        }

        let context = try await service.prepareContext(paths: [])
        try await syncFolderRecords(root: root, folders: Self.folders(in: context, root: root),
                                    verdicts: Dictionary(verdicts.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first }))
    }

    /// Moves or renames one folder whole, in one undoable step. False when the safety checks refuse it.
    private func moveFolder(_ source: String, to target: String, reason: String, _ summary: inout ArchiveRunSummary,
                            _ status: inout ArchiveRunProgress, _ progress: Progress) async throws -> Bool {
        let context = try await service.prepareContext(paths: [])
        guard let root = Self.workspace(context), source != target,
              context.directories.contains(where: { $0.rootID == root.id.uuidString && $0.relativePath == source }),
              !FileManager.default.fileExists(atPath: Self.url(target, in: root).path) else { return false }
        status.phase = .restructuring
        status.directory = "\(source) → \(target)"
        progress(status)
        guard let applied = try await apply(ArchiveAIResponse(summary: "把「\(source)」改为「\(target)」", directories: [
            ArchiveAIDirectoryRequest(action: .move, rootID: root.id.uuidString, relativePath: target, reason: reason, source: source),
        ], files: []), context: context, records: nil, &status, progress) else { return false }
        summary.movedDirectories += applied.directories.filter { $0.status == .complete }.count
        summary.batchIDs.append(applied.id)
        return true
    }

    /// Moves everything in `source` into `target`: subfolders whole when their name is free, otherwise merged in
    /// turn; files under their name normalized to the target's pattern, with the template's number field when that
    /// name is taken. Nothing is overwritten, and the emptied folder is removed. Every step is an undoable batch.
    private func mergeFolder(_ source: String, into target: String, depth: Int, reason: String, root: ArchiveFolder,
                             _ summary: inout ArchiveRunSummary, _ status: inout ArchiveRunProgress, _ progress: Progress) async throws {
        // Never into its own subfolder; a nested duplicate (`音乐/Songs` into `音乐`) is fine.
        guard depth <= 4, source != target, !target.hasPrefix(source + "/") else { return }
        var context = try await service.prepareContext(paths: [])
        let rootID = root.id.uuidString
        let sourceURL = Self.url(source, in: root)
        let targetURL = Self.url(target, in: root)
        status.phase = .restructuring
        status.directory = "\(source) → \(target)"
        progress(status)

        // Subfolders.
        let existing = Dictionary(Self.children(of: target, rootID: rootID, in: context).map { (ArchiveFileSystem.nameKey($0), $0) },
                                  uniquingKeysWith: { first, _ in first })
        var nested: [(String, String)] = []
        var moves: [ArchiveAIDirectoryRequest] = []
        for child in Self.children(of: source, rootID: rootID, in: context) {
            let childPath = source + "/" + child
            if let match = existing[ArchiveFileSystem.nameKey(child)] {
                // The source itself, when it sits inside the target, is not a place to merge into.
                if target + "/" + match != source { nested.append((childPath, target + "/" + match)) }
            } else if !Self.isTaken(child, in: targetURL, by: sourceURL.appendingPathComponent(child)) {
                moves.append(ArchiveAIDirectoryRequest(action: .move, rootID: rootID, relativePath: target + "/" + child,
                                                       reason: reason, source: childPath))
            }
        }
        for start in stride(from: 0, to: moves.count, by: 20) {
            context = try await service.prepareContext(paths: [])
            let chunk = Array(moves[start..<min(start + 20, moves.count)])
            guard let applied = try await apply(ArchiveAIResponse(summary: "把「\(source)」并入「\(target)」", directories: chunk, files: []),
                                                context: context, records: nil, &status, progress) else { continue }
            summary.movedDirectories += applied.directories.filter { $0.status == .complete }.count
            summary.batchIDs.append(applied.id)
        }
        for (from, to) in nested {
            try await mergeFolder(from, into: to, depth: depth + 1, reason: reason, root: root, &summary, &status, progress)
        }

        // Files lying directly in the folder.
        let paths = ArchiveStructureAudit.directFiles(sourceURL).map { sourceURL.appendingPathComponent($0).path }
        try await moveFiles(paths, into: target, root: root, reason: reason, title: "把「\(source)」并入「\(target)」",
                            &summary, &status, progress)

        // The emptied folder.
        context = try await service.prepareContext(paths: [])
        if context.directories.contains(where: { $0.rootID == rootID && $0.relativePath == source && $0.isEmpty }),
           let applied = try await apply(ArchiveAIResponse(summary: "删除已并入「\(target)」的空文件夹", directories: [
               ArchiveAIDirectoryRequest(action: .removeEmpty, rootID: rootID, relativePath: source, reason: reason),
           ], files: []), context: context, records: nil, &status, progress) {
            summary.removedDirectories += applied.directories.filter { $0.status == .complete }.count
            summary.batchIDs.append(applied.id)
        }
    }

    /// Moves files into `target` (or renames them where they are, when they are already there) under names
    /// normalized to the target's pattern, numbered when taken. Their records go with them.
    private func moveFiles(_ paths: [String], into target: String, root: ArchiveFolder, reason: String, title: String,
                           _ summary: inout ArchiveRunSummary, _ status: inout ArchiveRunProgress, _ progress: Progress) async throws {
        let targetURL = Self.url(target, in: root)
        for start in stride(from: 0, to: paths.count, by: 30) {
            try Task.checkCancellation()
            let context = try await service.prepareContext(paths: Array(paths[start..<min(start + 30, paths.count)]))
            let known = await service.snapshot().files ?? [:]
            var taken = Set(((try? FileManager.default.contentsOfDirectory(atPath: targetURL.path)) ?? []).map(ArchiveFileSystem.nameKey))
            var directories: [ArchiveAIDirectoryRequest] = []
            var requests: [ArchiveAIFileRequest] = []
            var records: [String: ArchiveFileRecord] = [:]
            for file in context.files {
                let original = file.source.lastPathComponent
                let from = (file.relativePath as NSString).deletingLastPathComponent
                let pattern = try await pattern(for: target, root: root, file: original)
                var name = ArchiveNameNormalizer.resolve(nil, original: original, pattern: pattern, rule: convention.naming).name
                if from == target { taken.remove(ArchiveFileSystem.nameKey(original)) }
                name = ArchiveNameNormalizer.distinguish(name, taken: taken)
                taken.insert(ArchiveFileSystem.nameKey(name))
                guard from != target || name != original else { continue }
                if !target.isEmpty, !context.directories.contains(where: { $0.rootID == file.rootID && $0.relativePath == target }),
                   directories.isEmpty {
                    directories.append(ArchiveAIDirectoryRequest(action: .create, rootID: file.rootID, relativePath: target, reason: reason))
                }
                requests.append(ArchiveAIFileRequest(fileID: file.id, rootID: file.rootID, relativeDirectory: target,
                                                     reason: reason, proposedName: name))
                if var record = known[file.source.path] {
                    if name != original { record.renamed = true }
                    if from != target, record.previousFolder == nil { record.previousFolder = from }
                    records[file.source.path] = record
                }
            }
            guard !requests.isEmpty,
                  let applied = try await apply(ArchiveAIResponse(summary: title, directories: directories, files: requests),
                                                context: context, records: records, &status, progress) else { continue }
            let moved = applied.files.filter { $0.status == .complete }
            summary.movedFiles += moved.filter { $0.source.deletingLastPathComponent() != $0.destination.deletingLastPathComponent() }.count
            summary.renamedFiles += moved.filter { $0.source.lastPathComponent != $0.destination.lastPathComponent }.count
            summary.createdDirectories += applied.directories.filter { $0.action == .create && $0.status == .complete }.count
            summary.batchIDs.append(applied.id)
            report(moved.map { operation in
                let renamed = operation.source.lastPathComponent != operation.destination.lastPathComponent
                let movedAway = operation.source.deletingLastPathComponent() != operation.destination.deletingLastPathComponent()
                var parts: [String] = []
                if movedAway { parts.append("已移到「\(target.isEmpty ? root.url.lastPathComponent : target)」") }
                if renamed { parts.append("已改名为 \(operation.destination.lastPathComponent)") }
                return ArchiveFileActivity(path: operation.source.path, status: .completed, detail: parts.joined(separator: " · "),
                                           record: records[operation.source.path].map { record in
                                               var record = record
                                               record.path = operation.destination.path
                                               record.operationID = operation.id
                                               return record
                                           })
            })
        }
    }

    /// Previews and applies one plan. Returns nil when the safety checks refuse it, so the caller can move on;
    /// a plan that fails halfway stops the run for review.
    private func apply(_ response: ArchiveAIResponse, context: ArchiveAIContext, records: [String: ArchiveFileRecord]?,
                       _ status: inout ArchiveRunProgress, _ progress: Progress) async throws -> ArchiveAIPlan? {
        let plan: ArchiveAIPlan
        do { plan = try await service.previewAI(response, contextID: context.id, records: records) }
        catch is ArchiveError { return nil }
        status.phase = .applying
        progress(status)
        let applied = try await service.applyAI(plan.id)
        guard applied.status == .complete else {
            throw ArchiveNeedsReview(applied.error ?? "部分更改未能确认，请在“整理记录”中核对。")
        }
        return applied
    }

    // MARK: Folder records and patterns

    /// The naming pattern of a folder: the one in its record, else derived from the files it holds now (or its
    /// category's default) and saved, so every later file follows it. Loose files in the workspace itself follow
    /// their own category's pattern.
    private func pattern(for folder: String, root: ArchiveFolder, file name: String) async throws -> ArchiveNamingPattern {
        guard !folder.isEmpty else { return convention.category(forFile: name)?.defaultPattern ?? .template }
        let url = Self.url(folder, in: root)
        let records = await service.snapshot().folders ?? [:]
        if let pattern = records[url.path]?.pattern { return pattern }
        let names = ArchiveStructureAudit.directFiles(url).filter { $0 != name }
        let fallback = ArchiveStructureAudit.defaultPattern(for: folder, record: records[url.path], convention: convention)
        let pattern = convention.naming.derivePattern(from: names, fallback: fallback)
        // A folder about to be created gets its record at the end of the run, from the files it then holds.
        if FileManager.default.fileExists(atPath: url.path) {
            var record = records[url.path] ?? ArchiveFolderRecord(path: url.path, category: convention.category(forFolderName: url.lastPathComponent)?.id)
            record.pattern = pattern
            try await service.saveFolderRecords([record])
        }
        return pattern
    }

    /// One record per folder of the tree: what the audit found (when it ran), the category the name stands for
    /// otherwise, and a naming pattern for every folder that holds files. Folders that are gone lose their record.
    private func syncFolderRecords(root: ArchiveFolder, folders: [String], verdicts: [String: ArchiveFolderVerdict] = [:]) async throws {
        let existing = await service.snapshot().folders ?? [:]
        var records: [ArchiveFolderRecord] = []
        for path in folders {
            let url = Self.url(path, in: root)
            var record = existing[url.path] ?? ArchiveFolderRecord(path: url.path)
            if let verdict = verdicts[path] {
                record.category = verdict.category
                record.isProject = verdict.isProject ? true : nil
                record.purity = verdict.purity
                record.auditedAt = Date()
            } else if record.category == nil, record.isProject != true {
                record.category = convention.category(forFolderName: url.lastPathComponent)?.id
            }
            if record.pattern == nil {
                let names = ArchiveStructureAudit.directFiles(url)
                if !names.isEmpty {
                    record.pattern = convention.naming.derivePattern(
                        from: names, fallback: ArchiveStructureAudit.defaultPattern(for: path, record: record, convention: convention))
                }
            }
            records.append(record)
        }
        try await service.replaceFolderRecords(records, inside: root.url.path)
    }

    /// The category's home when it exists, matched regardless of case.
    private func canonicalFolder(_ category: String, root: URL) -> String? {
        let key = ArchiveFileSystem.nameKey(convention.canonicalPath(category))
        let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                                     options: [.skipsHiddenFiles])) ?? []
        return entries.first { entry in
            (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && ArchiveFileSystem.nameKey(entry.lastPathComponent) == key
        }?.lastPathComponent
    }

    /// An existing folder the model named, or the home of the category its name means. Never a new folder.
    private func existingFolder(_ wanted: String, in folders: [String], root: URL) -> String? {
        let key = ArchiveFileSystem.nameKey(wanted)
        if let match = folders.first(where: { ArchiveFileSystem.nameKey($0) == key }) { return match }
        guard let category = convention.category(forFolderName: (wanted as NSString).lastPathComponent) else { return nil }
        return canonicalFolder(category.id, root: root)
    }

    // MARK: After the run – consistency check

    private func checkConsistency(audited: Bool, failure: String?, _ status: inout ArchiveRunProgress,
                                  _ progress: Progress) async throws -> ArchiveConsistencyReport? {
        let context = try await service.prepareContext(paths: [])
        guard let root = Self.workspace(context) else { return nil }
        status.phase = .checking
        progress(status)
        let folders = Self.folders(in: context, root: root)
        try await syncFolderRecords(root: root, folders: folders)
        let report = ArchiveStructureAudit.check(root: root.url, folders: folders, records: await service.snapshot().folders ?? [:],
                                                 convention: convention)
        try await service.saveConsistency(report)
        let previous = await service.snapshot().audit
        // Open items keep the audit coming back, but only for a few runs: what no run could settle is left to the user.
        let attempts = report.isClean ? 0 : (previous?.attempts ?? 0) + (audited ? 1 : 0)
        let state: ArchiveAuditState.Status = failure != nil ? .failed : (report.isClean ? .complete : .incomplete)
        try await service.saveAudit(ArchiveAuditState(structure: context.structure, status: state,
                                                      message: failure ?? (report.isClean ? nil : report.summary), attempts: attempts))
        return report
    }

    // MARK: Stage 2 – files in small batches, applied one at a time

    private func reviewFiles(since start: Date, _ summary: inout ArchiveRunSummary, _ status: inout ArchiveRunProgress,
                             _ progress: Progress) async throws {
        var waits = 0
        var round = 0
        while true {
            try Task.checkCancellation()
            guard round < maxRounds else { summary.hasMore = true; return }
            status.phase = .scanning
            status.batchFiles = 0
            status.receivedCharacters = 0
            progress(status)
            // Files whose record still matches their fingerprint are not offered again.
            let context = try await service.prepareAIContext(limit: batchSize, keywordLimit: keywordLimit, reviewedSince: start)
            status.remainingFiles = context.files.count + context.pendingCount
            if context.files.isEmpty {
                // Newly seen files must hold still for a moment before they are touched.
                if context.unsettledCount > 0, waits < 3 {
                    waits += 1
                    status.phase = .waitingForStableFiles
                    status.remainingFiles = context.unsettledCount
                    progress(status)
                    try await Task.sleep(for: stableWait)
                    continue
                }
                return
            }
            waits = 0
            round += 1
            status.round = round
            report(context.files.map { ArchiveFileActivity(path: $0.source.path, status: .queued, detail: "排队中") })
            guard let root = Self.workspace(context) else { return }
            var reviewed = context.files
            if sortsByType {
                let typed = reviewed.compactMap { file in ArchiveFileKind.of(name: file.source.lastPathComponent, size: file.fingerprint.size).map { (file, $0) } }
                if !typed.isEmpty {
                    let paths = Set(typed.map(\.0.source.path))
                    reviewed.removeAll { paths.contains($0.source.path) }
                    do { try await placeByType(typed, &summary, &status, progress) }
                    catch {
                        report(reviewed.map { ArchiveFileActivity(path: $0.source.path, status: .queued, detail: "已停止，下次继续") })
                        throw error
                    }
                }
            }
            let step = max(1, reviewBatch)
            // Read once per round: every folder with what it holds, so each file is compared with the whole tree.
            // Folders are read again after the type step, which may have created a category's home.
            var catalog = ArchiveFolderCatalog(folders: [])
            var folders: [String] = []
            var patterns: [String: String] = [:]
            if !reviewed.isEmpty {
                let fresh = try await service.prepareContext(paths: [])
                folders = Self.folders(in: fresh, root: root)
                let snapshot = await service.snapshot()
                catalog = ArchiveFolderCatalog.build(root: root.url, folders: folders, records: snapshot.files ?? [:])
                for folder in folders {
                    if let pattern = snapshot.folders?[Self.url(folder, in: root).path]?.pattern { patterns[folder] = pattern.label }
                }
            }
            for start in stride(from: 0, to: reviewed.count, by: step) {
                let chunk = Array(reviewed[start..<min(start + step, reviewed.count)])
                // One question for the whole chunk; the answers are then checked and applied file by file,
                // each against a fresh snapshot, so a move never relies on stale folder knowledge.
                let reviews = chunk.map { file in
                    ArchiveFileReview(file: file, folder: (file.relativePath as NSString).deletingLastPathComponent, folders: folders,
                                      siblings: Self.siblings(of: file.source, limit: siblingLimit),
                                      candidates: catalog.candidates(for: file, limit: candidateLimit))
                }
                report(chunk.map { ArchiveFileActivity(path: $0.source.path, status: .processing, detail: "正在判断位置、名称和内容") })
                status.phase = .reviewing
                status.directory = chunk.count == 1 ? chunk[0].source.lastPathComponent : "\(chunk.count) 个文件"
                status.batchFiles = chunk.count
                status.receivedCharacters = 0
                progress(status)
                let decisions: [String: ArchiveFileDecision]
                var lastError: String?
                do {
                    decisions = try await decide(reviews, folders: folders, patterns: patterns, lastError: &lastError)
                    // Not one file of several got an answer, even one at a time: the model is not working (it only
                    // thinks, or its answers are cut off). Stop here instead of placing a whole batch by guesswork.
                    if chunk.count > 1, decisions.isEmpty {
                        throw ArchiveNeedsReview("模型连续没有给出可用的结果（\(lastError ?? "原因未知")），已停止整理，文件都没有改动。请在模型设置中换用更快或非推理的模型后重试。")
                    }
                } catch is CancellationError {
                    report(reviewed[start...].map { ArchiveFileActivity(path: $0.source.path, status: .queued, detail: "已停止，下次继续") })
                    throw CancellationError()
                } catch {
                    report(chunk.map { ArchiveFileActivity(path: $0.source.path, status: .failed, detail: error.localizedDescription) })
                    report(reviewed[min(start + step, reviewed.count)...].map {
                        ArchiveFileActivity(path: $0.source.path, status: .queued, detail: "下次继续")
                    })
                    throw error
                }
                for (index, file) in chunk.enumerated() {
                    do {
                        try Task.checkCancellation()
                        try await apply(decisions[file.id], to: file, catalog: catalog, failure: lastError, &summary, &status, progress)
                    } catch is CancellationError {
                        report(chunk[index...].map { ArchiveFileActivity(path: $0.source.path, status: .queued, detail: "已停止，下次继续") })
                        report(reviewed[min(start + step, reviewed.count)...].map {
                            ArchiveFileActivity(path: $0.source.path, status: .queued, detail: "已停止，下次继续")
                        })
                        throw CancellationError()
                    } catch {
                        report([ArchiveFileActivity(path: file.source.path, status: .failed, detail: error.localizedDescription)])
                        report(chunk[(index + 1)...].map { ArchiveFileActivity(path: $0.source.path, status: .queued, detail: "下次继续") })
                        report(reviewed[min(start + step, reviewed.count)...].map {
                            ArchiveFileActivity(path: $0.source.path, status: .queued, detail: "下次继续")
                        })
                        throw error
                    }
                    status.processedFiles += 1
                    status.remainingFiles = max(0, status.remainingFiles - 1)
                    progress(status)
                }
            }
        }
    }

    /// Asks the model about a batch. An unavailable service gets one more try and then stops the run; an
    /// unusable answer splits the batch in half and asks again, down to single files, so one confusing file
    /// cannot sink the others. A single file with two unusable answers simply gets no decision.
    /// `lastError` keeps the most recent unusable answer, to say why when nothing came back.
    private func decide(_ reviews: [ArchiveFileReview], folders: [String], patterns: [String: String], attempt: Int = 1,
                        lastError: inout String?) async throws -> [String: ArchiveFileDecision] {
        guard !reviews.isEmpty else { return [:] }
        try Task.checkCancellation()
        do {
            let answer = try await planner.review(ArchiveBatchReview(folders: folders, files: reviews, patterns: patterns, convention: convention))
            try await rest()
            return answer
        } catch let error as ArchiveAIUnavailable {
            guard attempt < maxAttemptsPerRound else { throw error }
            return try await decide(reviews, folders: folders, patterns: patterns, attempt: attempt + 1, lastError: &lastError)
        } catch where error is ArchiveError || error is DecodingError {
            lastError = error.localizedDescription
            if reviews.count > 1 {
                let half = reviews.count / 2
                var merged = try await decide(Array(reviews[..<half]), folders: folders, patterns: patterns, lastError: &lastError)
                merged.merge(try await decide(Array(reviews[half...]), folders: folders, patterns: patterns, lastError: &lastError)) { first, _ in first }
                return merged
            }
            guard attempt < maxAttemptsPerRound else { return [:] }
            return try await decide(reviews, folders: folders, patterns: patterns, attempt: attempt + 1, lastError: &lastError)
        }
    }

    private func rest() async throws {
        guard cooldown > .zero else { return }
        try await Task.sleep(for: cooldown)
    }

    /// Checks one decision against a fresh snapshot, applies the change, and records the result in the same commit.
    /// A file the model cannot identify (or got no answer for) is still placed: kept in the subfolder the user put
    /// it in, moved next to clearly similar files, or collected in the unsorted folder when it lies loose. Its name
    /// always passes the normalizer with the destination's pattern.
    private func apply(_ decision: ArchiveFileDecision?, to scanned: ArchiveAIFile, catalog: ArchiveFolderCatalog, failure: String?,
                       _ summary: inout ArchiveRunSummary, _ status: inout ArchiveRunProgress, _ progress: Progress) async throws {
        let path = scanned.source.path
        status.phase = .reviewing
        status.directory = scanned.source.lastPathComponent
        status.batchFiles = 1
        progress(status)
        // A fresh snapshot for this file alone: the files before it may have changed the folders.
        let context = try await service.prepareFileContext(path: path, fingerprint: scanned.fingerprint, keywords: scanned.keywords)
        guard let file = context.files.first, let root = Self.workspace(context) else {
            report([ArchiveFileActivity(path: path, status: .queued, detail: "文件刚刚发生变化，下次重新处理")])
            return
        }
        let original = file.source.lastPathComponent
        let folder = (file.relativePath as NSString).deletingLastPathComponent
        let folders = Self.folders(in: context, root: root)

        let unknown = decision == nil || decision?.known == false
        var topic = Self.clean(decision?.topic, limit: 24)
        if topic.isEmpty { topic = Self.clean(scanned.metadata?["kind"], limit: 24) }
        var record = ArchiveFileRecord(path: path, fingerprint: file.fingerprint, originalName: original,
                                       topic: topic, renamed: false,
                                       reason: Self.clean(decision?.reason, limit: 300), stage: .named)
        record.summary = Self.clean(decision?.summary, limit: 120).isEmpty ? nil : Self.clean(decision?.summary, limit: 120)
        record.createdSeconds = ArchiveFileSystem.creationSeconds(file.source)
        var target = folder
        var notes: [String] = []
        if let decision {
            // Only a folder that already exists counts — after stage 1 a category's home or a project; a category's
            // synonym means its home. New folders come from grouping related files later.
            let wanted = Self.clean(decision.folder, limit: 1_000).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !wanted.isEmpty, wanted != folder, let existing = existingFolder(wanted, in: folders, root: root.url), existing != folder {
                if let confidence = decision.confidence, confidence < 0.4 {
                    notes.append("模型建议移到「\(existing)」但把握不足，暂不移动")
                } else {
                    target = existing
                }
            }
        }
        if unknown, target == folder, folder.isEmpty || folder == unsortedFolder {
            if folder.isEmpty, let match = catalog.confidentMatch(for: scanned) {
                target = match.path
                notes.append("无法判断内容，按名称与「\(match.path)」中的已有文件相似归入")
            } else if folder.isEmpty {
                target = unsortedFolder
                notes.append("无法判断是什么文件，先放进「\(unsortedFolder)」")
            }
        }
        // The name follows the destination's pattern; the model's proposal only counts when it knew the file.
        let pattern = try await pattern(for: target, root: root, file: original)
        let proposal = unknown ? nil : decision?.proposedName
        let resolution = ArchiveNameNormalizer.resolve(proposal, original: original, pattern: pattern, rule: convention.naming)
        var name = resolution.name
        if let suggestion = resolution.suggestion {
            record.suggestedName = Self.clean(suggestion, limit: 240)
            notes.append("建议的名称无法按命名规范纠正，未采用")
        }
        var taken = Set(((try? FileManager.default.contentsOfDirectory(atPath: Self.url(target, in: root).path)) ?? []).map(ArchiveFileSystem.nameKey))
        if target == folder { taken.remove(ArchiveFileSystem.nameKey(original)) }
        let free = ArchiveNameNormalizer.distinguish(name, taken: taken)
        if free != name {
            notes.append("「\(name)」已被占用，按命名规范加编号区分")
            name = free
        }
        if !notes.isEmpty { record.reason = notes.joined(separator: "；") }
        else if decision == nil { record.reason = "模型没有给出结果（\(failure ?? "原因未知")），按所在文件夹保留" }
        else if unknown, record.reason.isEmpty { record.reason = "无法判断内容，保留在所在文件夹" }
        let fits = decision?.belongsHere ?? !folder.isEmpty
        func settle(movedTo destination: String?) {
            if unknown {
                // Placed by rule, never left without a result. Files in the unsorted folder are looked at again
                // whenever the folders change, since a place may turn up for them.
                let final = destination ?? folder
                record.resolution = final == unsortedFolder || final.isEmpty ? .unplaced : .organized
                record.misplaced = nil
                record.stage = .grouped
            } else if destination != nil || (!folder.isEmpty && fits) {
                record.resolution = .organized
                record.misplaced = nil
                // A file staying in a folder where it belongs can still be grouped into a subfolder there.
                record.stage = destination != nil ? .grouped : .named
            } else {
                // Loose in the workspace, or not fitting its folder: grouped with other loose files next.
                record.resolution = .unplaced
                record.misplaced = folder.isEmpty ? nil : true
                record.stage = .named
            }
        }
        settle(movedTo: target != folder ? target : nil)
        // Looked at again without being moved now: what an earlier run changed stays on record, so the browser
        // still shows where the file came from and the earlier move can still be undone.
        if target == folder, name == original, let earlier = await service.snapshot().files?[path] {
            record.originalName = earlier.originalName
            record.renamed = earlier.renamed
            record.previousFolder = earlier.previousFolder
            record.operationID = earlier.operationID
        }
        // Checked against this layout: an unresolved file is not offered again until the folders change.
        record.structure = context.structure

        guard name != original || target != folder else {
            try await service.saveFileRecords([record])
            report([ArchiveFileActivity(path: path, status: Self.activity(for: record), detail: Self.describe(record), record: record)])
            if unknown { summary.leftUntouched += 1 }
            return
        }
        record.renamed = name != original
        if target != folder { record.previousFolder = folder }
        status.phase = .applying
        progress(status)
        let request = ArchiveAIFileRequest(fileID: file.id, rootID: file.rootID, relativeDirectory: target,
                                           reason: record.reason.isEmpty ? "位置或名称更合适" : record.reason, proposedName: name)
        // The unsorted folder is the only one this step may create; everything else must already exist.
        let creates = target != folder && !context.directories.contains { $0.rootID == file.rootID && $0.relativePath == target }
            ? [ArchiveAIDirectoryRequest(action: .create, rootID: file.rootID, relativePath: target, reason: "存放暂时无法识别的文件")] : []
        let plan: ArchiveAIPlan
        do {
            plan = try await service.previewAI(ArchiveAIResponse(summary: "整理「\(original)」", directories: creates, files: [request]),
                                               contextID: context.id, records: [path: record])
        } catch is ArchiveError {
            // The safety checks refused the change; record the file as it is instead.
            record.renamed = false
            record.previousFolder = nil
            if name != original { record.suggestedName = name }
            settle(movedTo: nil)
            record.reason = "更改未通过安全检查，保持原样"
            try await service.saveFileRecords([record])
            report([ArchiveFileActivity(path: path, status: Self.activity(for: record), detail: Self.describe(record), record: record)])
            return
        }
        // The move and the file's record are committed together.
        let applied = try await service.applyAI(plan.id)
        guard applied.status == .complete, let operation = applied.files.first, operation.status == .complete else {
            throw ArchiveNeedsReview(applied.error ?? "未能确认「\(original)」的更改，请在“整理记录”中核对。")
        }
        if record.renamed { summary.renamedFiles += 1 }
        if target != folder { summary.movedFiles += 1 }
        summary.createdDirectories += applied.directories.filter { $0.action == .create && $0.status == .complete }.count
        summary.batchIDs.append(applied.id)
        record.path = operation.destination.path
        record.operationID = operation.id
        report([ArchiveFileActivity(path: path, status: .completed,
                                    detail: Self.describe(record, movedTo: target != folder ? (target as NSString).lastPathComponent : nil),
                                    record: record)])
    }

    // MARK: Stage 2a – files sorted by type alone

    /// Files whose type says enough (`ArchiveFileKind`). The only question is whether the file already lies in its
    /// category's canonical path or below it; if not, it goes there, created in the workspace when missing. Its
    /// name is normalized to that folder's pattern either way. No model request, no content read; the moves go
    /// through the same checked, undoable plans as everything else.
    private func placeByType(_ files: [(ArchiveAIFile, ArchiveFileKind)], _ summary: inout ArchiveRunSummary,
                             _ status: inout ArchiveRunProgress, _ progress: Progress) async throws {
        let context = try await service.prepareContext(paths: [])
        guard let root = Self.workspace(context) else { return }
        let rootID = root.id.uuidString
        status.phase = .reviewing
        status.directory = "按类型归类 \(files.count) 个文件"
        status.batchFiles = files.count
        progress(status)
        report(files.map { ArchiveFileActivity(path: $0.0.source.path, status: .processing, detail: "按文件类型归类") })

        var takenByFolder: [String: Set<String>] = [:]
        func taken(in folder: String) -> Set<String> {
            if let known = takenByFolder[folder] { return known }
            let names = Set(((try? FileManager.default.contentsOfDirectory(atPath: Self.url(folder, in: root).path)) ?? []).map(ArchiveFileSystem.nameKey))
            takenByFolder[folder] = names
            return names
        }
        var stays: [ArchiveFileRecord] = []
        var moves: [(file: ArchiveAIFile, kind: ArchiveFileKind, target: String, name: String)] = []
        for (file, kind) in files {
            let folder = (file.relativePath as NSString).deletingLastPathComponent
            let original = file.source.lastPathComponent
            let home = canonicalFolder(kind.category, root: root.url) ?? convention.canonicalPath(kind.category)
            let homeKey = ArchiveFileSystem.nameKey(home)
            let folderKey = ArchiveFileSystem.nameKey(folder)
            let inPlace = folderKey == homeKey || folderKey.hasPrefix(homeKey + "/")
            let target = inPlace ? folder : home
            let pattern = try await pattern(for: target, root: root, file: original)
            var names = taken(in: target)
            if inPlace { names.remove(ArchiveFileSystem.nameKey(original)) }
            let name = ArchiveNameNormalizer.distinguish(
                ArchiveNameNormalizer.resolve(nil, original: original, pattern: pattern, rule: convention.naming).name, taken: names)
            if inPlace && name == original {
                var record = ArchiveFileRecord(path: file.source.path, fingerprint: file.fingerprint, originalName: original,
                                               topic: kind.topic, renamed: false, reason: "已在「\(home)」中，保持不变", stage: .grouped)
                record.summary = "\(kind.topic)文件，按类型归类，未发送给 AI"
                record.createdSeconds = ArchiveFileSystem.creationSeconds(file.source)
                record.resolution = .organized
                record.structure = context.structure
                stays.append(record)
            } else {
                takenByFolder[target] = names.union([ArchiveFileSystem.nameKey(name)])
                moves.append((file, kind, target, name))
            }
        }
        try await service.saveFileRecords(stays)
        report(stays.map { ArchiveFileActivity(path: $0.path, status: Self.activity(for: $0), detail: Self.describe($0), record: $0) })
        status.processedFiles += stays.count
        status.remainingFiles = max(0, status.remainingFiles - stays.count)
        progress(status)

        // The service accepts at most 30 file moves per plan; each slice gets a fresh snapshot.
        for start in stride(from: 0, to: moves.count, by: 30) {
            let slice = moves[start..<min(start + 30, moves.count)]
            let fresh: ArchiveAIContext
            do {
                try Task.checkCancellation()
                fresh = try await service.prepareContext(paths: slice.map(\.file.source.path))
            } catch {
                report(moves[start...].map { ArchiveFileActivity(path: $0.file.source.path, status: .queued, detail: "已停止，下次继续") })
                throw error
            }
            var directories: [ArchiveAIDirectoryRequest] = []
            var requests: [ArchiveAIFileRequest] = []
            var records: [String: ArchiveFileRecord] = [:]
            for item in slice {
                guard let file = fresh.files.first(where: { $0.source.path == item.file.source.path }) else { continue }
                let from = (file.relativePath as NSString).deletingLastPathComponent
                let reason = from == item.target ? "按「\(item.target)」的命名模式改名" : "\(item.kind.topic)文件按类型放进「\(item.target)」"
                if !item.target.isEmpty, !fresh.directories.contains(where: { $0.rootID == rootID && $0.relativePath == item.target }),
                   !directories.contains(where: { $0.relativePath == item.target }) {
                    directories.append(ArchiveAIDirectoryRequest(action: .create, rootID: rootID, relativePath: item.target, reason: reason))
                }
                var record = ArchiveFileRecord(path: file.source.path, fingerprint: file.fingerprint, originalName: file.source.lastPathComponent,
                                               topic: item.kind.topic, renamed: item.name != file.source.lastPathComponent, reason: reason, stage: .grouped)
                record.summary = "\(item.kind.topic)文件，按类型归类，未发送给 AI"
                record.createdSeconds = ArchiveFileSystem.creationSeconds(file.source)
                record.resolution = .organized
                if from != item.target { record.previousFolder = from }
                records[file.source.path] = record
                requests.append(ArchiveAIFileRequest(fileID: file.id, rootID: file.rootID, relativeDirectory: item.target,
                                                     reason: reason, proposedName: item.name))
            }
            guard !requests.isEmpty else { continue }
            status.phase = .applying
            progress(status)
            let plan: ArchiveAIPlan
            do {
                plan = try await service.previewAI(ArchiveAIResponse(summary: "按文件类型归类", directories: directories, files: requests),
                                                   contextID: fresh.id, records: records)
            } catch is ArchiveError {
                report(slice.map { ArchiveFileActivity(path: $0.file.source.path, status: .queued, detail: "更改未通过安全检查，下次重新处理") })
                continue
            }
            let applied = try await service.applyAI(plan.id)
            guard applied.status == .complete else {
                throw ArchiveNeedsReview(applied.error ?? "部分文件未能确认移动，请在“整理记录”中核对。")
            }
            let moved = applied.files.filter { $0.status == .complete }
            summary.movedFiles += moved.filter { $0.source.deletingLastPathComponent() != $0.destination.deletingLastPathComponent() }.count
            summary.renamedFiles += moved.filter { $0.source.lastPathComponent != $0.destination.lastPathComponent }.count
            summary.createdDirectories += applied.directories.filter { $0.action == .create && $0.status == .complete }.count
            summary.batchIDs.append(applied.id)
            for operation in moved {
                var record = records[operation.source.path]
                record?.path = operation.destination.path
                record?.operationID = operation.id
                report([ArchiveFileActivity(path: operation.source.path, status: .completed,
                                            detail: "已按类型归入「\(operation.destination.deletingLastPathComponent().lastPathComponent)」", record: record)])
            }
            status.processedFiles += slice.count
            status.remainingFiles = max(0, status.remainingFiles - slice.count)
            progress(status)
        }
    }

    // MARK: Stage 3 – files into folders

    /// Returns the folders that gained new subfolders, for the folder-level step.
    private func groupFiles(_ summary: inout ArchiveRunSummary, _ status: inout ArchiveRunProgress, _ progress: Progress) async throws -> Set<String> {
        var changed = Set<String>()
        let workspace = await service.snapshot().configuration.folders.first { $0.role == .workspace }?.url.path ?? ""
        while true {
            try Task.checkCancellation()
            let waiting = (await service.snapshot().files ?? [:]).values.filter { $0.stage == .named }
            // A file that does not fit its folder is grouped with the workspace's loose files, so it can move to
            // a category anywhere instead of into a subfolder of the folder it does not belong to.
            let byFolder = Dictionary(grouping: waiting) { record in
                record.misplaced == true && !workspace.isEmpty ? workspace : (record.path as NSString).deletingLastPathComponent
            }
            // Deepest folders first, so lower levels settle before the folders above them.
            guard let folder = byFolder.keys.max(by: Self.deeperLast) else { return changed }
            let records = (byFolder[folder] ?? []).sorted { ($0.topic, $0.path) < ($1.topic, $1.path) }
            if try await groupChunk(Array(records.prefix(groupingLimit)), in: folder, &summary, &status, progress) {
                changed.insert(folder)
            }
        }
    }

    /// Every record in `records` leaves the `named` stage here, moved or not, so the step always ends.
    private func groupChunk(_ records: [ArchiveFileRecord], in folder: String, _ summary: inout ArchiveRunSummary,
                            _ status: inout ArchiveRunProgress, _ progress: Progress) async throws -> Bool {
        var unfinished = Set(records.map(\.path))
        report(records.map { ArchiveFileActivity(path: $0.path, status: .processing, detail: "正在归类") })
        do {
            let context = try await service.prepareRecordedContext(paths: records.map(\.path))
            let present = Set(context.files.map(\.source.path))
            unfinished.formIntersection(present)
            guard let root = Self.workspace(context) else {
                try await service.saveFileRecords(records.filter { present.contains($0.path) }.map { record in
                    var record = record
                    record.stage = .grouped
                    return record
                })
                return false
            }
            let relative = ArchiveDirectoryFileSystem.relativePath(URL(fileURLWithPath: folder), root: root.url)
            let byPath = Dictionary(records.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
            let subfolders = Self.children(of: relative, rootID: root.id.uuidString, in: context)
            status.phase = .grouping
            status.directory = relative.isEmpty ? root.url.lastPathComponent : relative
            status.batchFiles = context.files.count
            status.receivedCharacters = 0
            progress(status)

            var groups: [Group] = []
            var leftReason = "属于当前文件夹，保持不变"
            if context.files.count >= 2 || (!context.files.isEmpty && !subfolders.isEmpty) {
                let request = ArchiveGroupingRequest(directory: relative, subfolders: subfolders, files: context.files.map {
                    .init(id: $0.id, name: $0.source.lastPathComponent, topic: byPath[$0.source.path]?.topic ?? "")
                }, convention: convention)
                do {
                    groups = validGroups(try await planner.group(request), files: context.files, subfolders: subfolders,
                                         relative: relative, root: root)
                    try await rest()
                } catch where error is ArchiveError || error is DecodingError {
                    leftReason = "没有得到有效的归类方案，保持不变"
                }
            }

            var created = false
            var takenByTarget: [String: Set<String>] = [:]
            let assignments = groups.flatMap { group in group.files.map { (target: group.target, reason: group.reason, path: $0.source.path) } }
            // The service accepts at most 30 file moves per plan; each slice gets a fresh snapshot.
            for start in stride(from: 0, to: assignments.count, by: 30) {
                let slice = assignments[start..<min(start + 30, assignments.count)]
                let fresh = try await service.prepareRecordedContext(paths: slice.map(\.path))
                var directories: [ArchiveAIDirectoryRequest] = []
                var requests: [ArchiveAIFileRequest] = []
                var planRecords: [String: ArchiveFileRecord] = [:]
                for item in slice {
                    guard let file = fresh.files.first(where: { $0.source.path == item.path }), var record = byPath[item.path] else { continue }
                    let target = item.target
                    if !fresh.directories.contains(where: { $0.rootID == file.rootID && $0.relativePath == target }),
                       !directories.contains(where: { $0.relativePath == target }) {
                        directories.append(ArchiveAIDirectoryRequest(action: .create, rootID: file.rootID, relativePath: target, reason: item.reason))
                    }
                    // The name follows the destination's pattern and never takes one already there.
                    let original = file.source.lastPathComponent
                    let pattern = try await pattern(for: target, root: root, file: original)
                    let taken = takenByTarget[target]
                        ?? Set(((try? FileManager.default.contentsOfDirectory(atPath: Self.url(target, in: root).path)) ?? []).map(ArchiveFileSystem.nameKey))
                    let name = ArchiveNameNormalizer.distinguish(
                        ArchiveNameNormalizer.resolve(nil, original: original, pattern: pattern, rule: convention.naming).name, taken: taken)
                    takenByTarget[target] = taken.union([ArchiveFileSystem.nameKey(name)])
                    record.stage = .grouped
                    record.resolution = .organized
                    record.misplaced = nil
                    record.processedAt = Date()
                    if name != original { record.renamed = true }
                    // Only the first move away from where the user left the file is worth showing.
                    if record.previousFolder == nil { record.previousFolder = (file.relativePath as NSString).deletingLastPathComponent }
                    planRecords[item.path] = record
                    requests.append(ArchiveAIFileRequest(fileID: file.id, rootID: file.rootID, relativeDirectory: target,
                                                         reason: item.reason, proposedName: name))
                }
                guard !requests.isEmpty else { continue }
                status.phase = .applying
                progress(status)
                let plan: ArchiveAIPlan
                do {
                    plan = try await service.previewAI(ArchiveAIResponse(summary: "把相关文件放进同一个文件夹", directories: directories, files: requests),
                                                       contextID: fresh.id, records: planRecords)
                } catch is ArchiveError { continue }
                let applied = try await service.applyAI(plan.id)
                guard applied.status == .complete else {
                    throw ArchiveNeedsReview(applied.error ?? "部分文件未能确认移动，请在“整理记录”中核对。")
                }
                let moved = applied.files.filter { $0.status == .complete }
                let made = applied.directories.filter { $0.action == .create && $0.status == .complete }.count
                summary.movedFiles += moved.count
                summary.renamedFiles += moved.filter { $0.source.lastPathComponent != $0.destination.lastPathComponent }.count
                summary.createdDirectories += made
                summary.batchIDs.append(applied.id)
                created = created || made > 0
                for operation in moved {
                    unfinished.remove(operation.source.path)
                    var record = planRecords[operation.source.path]
                    record?.path = operation.destination.path
                    record?.operationID = operation.id
                    report([ArchiveFileActivity(path: operation.source.path, status: .completed,
                                                detail: "已归入「\(operation.destination.deletingLastPathComponent().lastPathComponent)」", record: record)])
                }
            }

            // Files that belong where they are stay organized. Loose or misfiled ones with no clear destination
            // stay too, but as unplaced: they are reviewed again once the folders or the workspace change.
            let rest = records.filter { unfinished.contains($0.path) }.map { record -> ArchiveFileRecord in
                var record = record
                record.stage = .grouped
                record.structure = nil
                record.processedAt = Date()
                return record
            }
            try await service.saveFileRecords(rest)
            report(rest.map { record in
                record.isResolved ? ArchiveFileActivity(path: record.path, status: .completed, detail: leftReason, record: record)
                    : ArchiveFileActivity(path: record.path, status: .unplaced, detail: Self.describe(record), record: record)
            })
            unfinished.removeAll()
            return created
        } catch is CancellationError {
            report(unfinished.map { ArchiveFileActivity(path: $0, status: .queued, detail: "已停止，下次继续") })
            throw CancellationError()
        } catch {
            report(unfinished.map { ArchiveFileActivity(path: $0, status: .failed, detail: error.localizedDescription) })
            throw error
        }
    }

    private struct Group {
        /// Relative to the workspace.
        var target: String
        var files: [ArchiveAIFile]
        var reason: String
    }

    /// Keeps only groups that are safe and worth having: a name that passes the convention (a category's synonym
    /// becomes its canonical name, and its files go to the category's one home), known files listed once,
    /// existing folders reused regardless of case, and no new folder for a single file.
    private func validGroups(_ answer: ArchiveGroupingResponse, files: [ArchiveAIFile], subfolders: [String],
                             relative: String, root: ArchiveFolder) -> [Group] {
        let byID = Dictionary(files.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var used = Set<String>()
        var targets = Set<String>()
        var result: [Group] = []
        func join(_ name: String) -> String { relative.isEmpty ? name : relative + "/" + name }
        for group in answer.groups {
            guard let name = ArchiveFolderNaming.normalize(group.folder, convention: convention) else { continue }
            let target: String
            if let category = convention.category(forFolderName: name), convention.topLevel == .category || relative.isEmpty {
                target = canonicalFolder(category.id, root: root.url) ?? convention.canonicalPath(category.id)
            } else {
                target = join(subfolders.first { ArchiveFileSystem.nameKey($0) == ArchiveFileSystem.nameKey(name) } ?? name)
            }
            guard target != relative, Self.depth(target) <= depthLimit,
                  targets.insert(ArchiveFileSystem.nameKey(target)).inserted else { continue }
            let existing = FileManager.default.fileExists(atPath: Self.url(target, in: root).path)
            let members = group.fileIDs.compactMap { id -> ArchiveAIFile? in
                guard let file = byID[id], !used.contains(id) else { return nil }
                return file
            }
            guard members.count >= (existing ? 1 : 2) else { continue }
            members.forEach { used.insert($0.id) }
            let reason = Self.clean(group.reason, limit: 300)
            result.append(Group(target: target, files: members, reason: reason.isEmpty ? "相关文件放在一起" : reason))
        }
        return result
    }

    // MARK: Stage 4 – folder levels

    private func nestFolders(_ changed: Set<String>, _ summary: inout ArchiveRunSummary,
                             _ status: inout ArchiveRunProgress, _ progress: Progress) async throws {
        // Deepest first: a level is settled before the level above it is looked at.
        for folder in changed.sorted(by: { Self.deeperLast($1, $0) }) {
            for _ in 0..<maxNestingPasses {
                try Task.checkCancellation()
                guard try await nestOnce(in: folder, &summary, &status, progress) else { break }
            }
        }
    }

    /// One review of a folder's subfolders. Returns true when a new level was added, so another pass can
    /// check whether the new folders group further. Category homes in the workspace never move or change name.
    private func nestOnce(in folder: String, _ summary: inout ArchiveRunSummary,
                          _ status: inout ArchiveRunProgress, _ progress: Progress) async throws -> Bool {
        let context = try await service.prepareRecordedContext(paths: [])
        guard let root = Self.workspace(context), ArchiveFileSystem.contains(URL(fileURLWithPath: folder), in: root.url),
              FileManager.default.fileExists(atPath: folder) else { return false }
        let rootID = root.id.uuidString
        let relative = ArchiveDirectoryFileSystem.relativePath(URL(fileURLWithPath: folder), root: root.url)
        let names = Self.children(of: relative, rootID: rootID, in: context)
        let isHome = { (name: String) in relative.isEmpty && self.convention.category(forFolderName: name) != nil }
        let movable = names.filter { !isHome($0) }
        guard movable.count >= 3 else { return false }
        func path(_ name: String) -> String { relative.isEmpty ? name : relative + "/" + name }
        func subtreeDepth(_ name: String) -> Int {
            let prefix = path(name) + "/"
            return context.directories.filter { $0.rootID == rootID && $0.relativePath.hasPrefix(prefix) }
                .map { Self.depth($0.relativePath) - Self.depth(path(name)) }.max() ?? 0
        }
        /// A new or changed name: it must pass the convention, and may only be a category's name where it becomes
        /// that category's home.
        func acceptable(_ raw: String) -> String? {
            guard let name = ArchiveFolderNaming.normalize(raw, convention: convention) else { return nil }
            if let category = convention.category(forFolderName: name) {
                guard relative.isEmpty, canonicalFolder(category.id, root: root.url) == nil else { return nil }
            }
            return name
        }
        status.phase = .nesting
        status.directory = relative.isEmpty ? root.url.lastPathComponent : relative
        status.batchFiles = 0
        status.receivedCharacters = 0
        progress(status)
        let request = ArchiveNestingRequest(directory: relative, folders: names.prefix(80).map { name in
            let contents = Self.summarize(URL(fileURLWithPath: folder).appendingPathComponent(name, isDirectory: true))
            return .init(name: name, fileCount: contents.count, samples: contents.samples,
                         subfolders: Self.children(of: path(name), rootID: rootID, in: context))
        }, convention: convention)
        let answer: ArchiveNestingResponse
        do { answer = try await planner.nest(request); try await rest() }
        catch where error is ArchiveError || error is DecodingError { return false }

        let existing = Dictionary(movable.map { (ArchiveFileSystem.nameKey($0), $0) }, uniquingKeysWith: { first, _ in first })
        var taken = Set(names.map(ArchiveFileSystem.nameKey))
        var used = Set<String>()
        var directories: [ArchiveAIDirectoryRequest] = []
        var addsLevel = false
        for group in answer.groups ?? [] {
            guard let name = acceptable(group.folder), !taken.contains(ArchiveFileSystem.nameKey(name)) else { continue }
            let members = Set(group.children.compactMap { existing[ArchiveFileSystem.nameKey($0)] })
                .filter { !used.contains($0) && Self.depth(relative) + 2 + subtreeDepth($0) <= depthLimit }
                .sorted()
            // A new level must gather at least two folders and must not just wrap the whole level.
            guard members.count >= 2, members.count < movable.count, directories.count + 1 + members.count <= 20 else { continue }
            let reason = Self.clean(group.reason, limit: 300).isEmpty ? "相关文件夹放在一起" : Self.clean(group.reason, limit: 300)
            taken.insert(ArchiveFileSystem.nameKey(name))
            used.formUnion(members)
            directories.append(ArchiveAIDirectoryRequest(action: .create, rootID: rootID, relativePath: path(name), reason: reason))
            for member in members {
                directories.append(ArchiveAIDirectoryRequest(action: .move, rootID: rootID, relativePath: path(name) + "/" + member,
                                                             reason: reason, source: path(member)))
            }
            addsLevel = true
        }
        for rename in answer.renames ?? [] {
            guard let from = existing[ArchiveFileSystem.nameKey(rename.from)], !used.contains(from),
                  let name = acceptable(rename.to), !taken.contains(ArchiveFileSystem.nameKey(name)),
                  directories.count < 20 else { continue }
            let reason = Self.clean(rename.reason, limit: 300).isEmpty ? "名称更清楚" : Self.clean(rename.reason, limit: 300)
            taken.insert(ArchiveFileSystem.nameKey(name))
            used.insert(from)
            directories.append(ArchiveAIDirectoryRequest(action: .move, rootID: rootID, relativePath: path(name), reason: reason, source: path(from)))
        }
        guard !directories.isEmpty else { return false }

        status.phase = .applying
        progress(status)
        let plan: ArchiveAIPlan
        do {
            plan = try await service.previewAI(ArchiveAIResponse(summary: Self.clean(answer.summary, limit: 2_000).isEmpty ? "整理文件夹层级" : Self.clean(answer.summary, limit: 2_000),
                                                                 directories: directories, files: []), contextID: context.id)
        } catch is ArchiveError { return false }
        let applied = try await service.applyAI(plan.id)
        guard applied.status == .complete else {
            throw ArchiveNeedsReview(applied.error ?? "部分文件夹未能确认移动，请在“整理记录”中核对。")
        }
        summary.createdDirectories += applied.directories.filter { $0.action == .create && $0.status == .complete }.count
        summary.movedDirectories += applied.directories.filter { $0.action == .move && $0.status == .complete }.count
        summary.batchIDs.append(applied.id)
        return addsLevel
    }

    // MARK: Helpers

    private static func workspace(_ context: ArchiveAIContext) -> ArchiveFolder? {
        context.folders.first { $0.role == .workspace }
    }

    /// Every folder of the workspace, relative paths, sorted.
    private static func folders(in context: ArchiveAIContext, root: ArchiveFolder) -> [String] {
        context.directories.filter { $0.rootID == root.id.uuidString && !$0.relativePath.isEmpty }.map(\.relativePath).sorted()
    }

    private static func url(_ relative: String, in root: ArchiveFolder) -> URL {
        relative.isEmpty ? root.url : root.url.appendingPathComponent(relative, isDirectory: true)
    }

    private static func children(of relative: String, rootID: String, in context: ArchiveAIContext) -> [String] {
        context.directories.filter {
            $0.rootID == rootID && !$0.relativePath.isEmpty && ($0.relativePath as NSString).deletingLastPathComponent == relative
        }.map { ($0.relativePath as NSString).lastPathComponent }.sorted()
    }

    private static func depth(_ path: String) -> Int { path.split(separator: "/").count }

    /// Orders paths so the deepest (then alphabetically first) one compares as the largest.
    private static func deeperLast(_ lhs: String, _ rhs: String) -> Bool {
        depth(lhs) != depth(rhs) ? depth(lhs) < depth(rhs) : lhs > rhs
    }

    /// How many files a folder holds and a few of their names, for the folder questions.
    private static func summarize(_ url: URL, recursive: Bool = true) -> (count: Int, samples: [String]) {
        var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        if !recursive { options.insert(.skipsSubdirectoryDescendants) }
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                                              options: options) else { return (0, []) }
        var count = 0
        var samples: [String] = []
        for case let item as URL in enumerator {
            guard (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            count += 1
            if samples.count < 6 { samples.append(item.lastPathComponent) }
            if count >= 2_000 { break }
        }
        return (count, samples)
    }

    /// A few other visible files in the same folder, so the model can judge whether this one fits with them.
    private static func siblings(of file: URL, limit: Int) -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)) ?? []
        return Array(entries.filter { !$0.hasPrefix(".") && $0 != file.lastPathComponent }.sorted().prefix(max(0, limit)))
    }

    private static func isTaken(_ name: String, in folder: URL, by source: URL) -> Bool {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return entries.contains { $0 != source.lastPathComponent && ArchiveFileSystem.nameKey($0) == ArchiveFileSystem.nameKey(name) }
    }

    private static func activity(for record: ArchiveFileRecord) -> ArchiveFileActivity.Status {
        switch record.resolution ?? .organized {
        case .organized: .completed
        case .unplaced: .unplaced
        case .unrecognized: .skipped
        }
    }

    private static func clean(_ text: String?, limit: Int) -> String {
        String((text ?? "").split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
    }

    private static func describe(_ record: ArchiveFileRecord, movedTo folder: String? = nil) -> String {
        var parts: [String] = []
        if let folder { parts.append("已移到「\(folder)」") }
        if record.renamed { parts.append("已改名为 \((record.path as NSString).lastPathComponent)") }
        if parts.isEmpty {
            switch record.resolution ?? .organized {
            case .unplaced where record.stage == .named: parts.append("暂未找到合适的文件夹，接下来与相关文件一起归类")
            case .unplaced: parts.append("暂无合适的文件夹，留在原处；文件夹变化后会再看")
            default: parts.append(record.reason.isEmpty ? "位置和名称合适，保持不变" : record.reason)
            }
        }
        if let suggestion = record.suggestedName, !record.renamed { parts.append("建议名称：\(suggestion)") }
        if !record.topic.isEmpty { parts.append(record.topic) }
        return parts.joined(separator: " · ")
    }
}
