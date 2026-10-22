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
        /// Step 0: merging folders that mean the same thing.
        case consolidating
        /// New files must hold still briefly before they are touched.
        case waitingForStableFiles
        /// Step 1: reviewing one file's place, name and topic.
        case reviewing
        /// Step 2: putting related files of one folder into subfolders.
        case grouping
        /// Step 3: grouping related folders under a new level.
        case nesting
        case applying
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
    var name: String { (path as NSString).lastPathComponent }
}

/// Runs the whole organize cycle without user decisions, in steps that each finish before the next:
/// 0. merge folders that mean the same thing (`Downloads/music` into `音乐`), when the folder layout changed;
/// 1. review every new or changed file on its own, one after another: keep it or move it to an existing folder
///    that fits better, improve its name when the evidence supports it, and save the result right away;
/// 2. put related files still left loose — in the workspace itself, or not fitting their folder — into new or
///    existing folders; files with nowhere to go stay, recorded as unplaced;
/// 3. group related folders under new levels, bottom up, one level per pass.
/// Safety checks stay in `ArchiveService`; autopilot only sequences them and never bypasses them.
@MainActor
struct ArchiveAutopilot {
    typealias Progress = @MainActor (ArchiveRunProgress) -> Void

    let service: ArchiveService
    let planner: ArchiveStagePlanner
    var stableWait: Duration = .milliseconds(2_300)
    var maxRounds = 60
    var maxAttemptsPerRound = 2
    /// Files taken from each scan; they are still reviewed one at a time.
    var batchSize = 30
    var keywordLimit = 80
    /// Files of one folder shown to the planner at once when grouping.
    var groupingLimit = 60
    /// Folder levels one run may add inside a single folder.
    var maxNestingPasses = 2
    /// Grouping folders never pushes anything deeper than this below the workspace.
    var maxDepth = 4
    /// Receives per-file status changes as the run moves through each batch.
    var report: @MainActor ([ArchiveFileActivity]) -> Void = { _ in }

    func run(progress: Progress = { _ in }) async throws -> ArchiveRunSummary {
        var summary = ArchiveRunSummary()
        var status = ArchiveRunProgress()
        let start = Date()
        let consolidated = try await consolidateFolders(&summary, &status, progress)
        try await reviewFiles(&summary, &status, progress)
        // Grouping waits until every new file has been reviewed, so related files are seen together.
        if !summary.hasMore {
            let changed = try await groupFiles(&summary, &status, progress)
            try await nestFolders(changed, &summary, &status, progress)
        }
        // Unresolved files are skipped until the layout differs from what they were last checked against.
        try await service.stampUnresolved(since: start)
        if consolidated { try await service.markConsolidated(try await service.structureSignature()) }
        return summary
    }

    // MARK: Step 0 – folders that mean the same thing

    /// Returns true when the folder layout was reviewed for equivalent folders in this run.
    private func consolidateFolders(_ summary: inout ArchiveRunSummary, _ status: inout ArchiveRunProgress,
                                    _ progress: Progress) async throws -> Bool {
        try Task.checkCancellation()
        let structure = try await service.structureSignature()
        guard await service.snapshot().consolidatedStructure != structure else { return false }
        let context = try await service.prepareContext(paths: [])
        guard let root = Self.workspace(context) else { return false }
        let rootID = root.id.uuidString
        let folders = context.directories.filter { $0.rootID == rootID && !$0.relativePath.isEmpty }.map(\.relativePath).sorted()
        guard folders.count >= 2 else { return true }
        status.phase = .consolidating
        status.directory = root.url.lastPathComponent
        status.receivedCharacters = 0
        progress(status)
        let request = ArchiveConsolidationRequest(folders: folders.prefix(300).map { path in
            let contents = Self.summarize(root.url.appendingPathComponent(path, isDirectory: true), recursive: false)
            return .init(path: path, fileCount: contents.count, samples: contents.samples)
        })
        let answer: ArchiveConsolidationResponse
        do { answer = try await planner.consolidate(request) }
        catch where error is ArchiveError || error is DecodingError { return true }

        let known = Dictionary(folders.map { (ArchiveFileSystem.nameKey($0), $0) }, uniquingKeysWith: { first, _ in first })
        var used = Set<String>()
        for merge in answer.merges {
            guard let keep = known[ArchiveFileSystem.nameKey(Self.clean(merge.keep, limit: 1_000))], !used.contains(keep) else { continue }
            let sources = merge.merge.compactMap { known[ArchiveFileSystem.nameKey(Self.clean($0, limit: 1_000))] }.filter { source in
                // Never into itself, its own parent or its own child.
                source != keep && !source.hasPrefix(keep + "/") && !keep.hasPrefix(source + "/") && !used.contains(source)
            }
            guard !sources.isEmpty else { continue }
            used.insert(keep)
            let reason = Self.clean(merge.reason, limit: 300).isEmpty ? "含义相同的文件夹合并" : Self.clean(merge.reason, limit: 300)
            for source in sources {
                used.insert(source)
                // An earlier merge may have moved this folder already.
                guard FileManager.default.fileExists(atPath: root.url.appendingPathComponent(source).path),
                      FileManager.default.fileExists(atPath: root.url.appendingPathComponent(keep).path) else { continue }
                try await mergeFolder(source, into: keep, depth: 0, reason: reason, &summary, &status, progress)
            }
        }
        return true
    }

    /// Moves everything in `source` into `target`: subfolders whole when their name is free, otherwise merged in
    /// turn; files under their own name, or `name (2).ext` when it is taken. Nothing is overwritten, and the
    /// emptied folder is removed. Every step is a journaled batch that can be undone.
    private func mergeFolder(_ source: String, into target: String, depth: Int, reason: String,
                             _ summary: inout ArchiveRunSummary, _ status: inout ArchiveRunProgress, _ progress: Progress) async throws {
        guard depth <= 4 else { return }
        var context = try await service.prepareContext(paths: [])
        guard let root = Self.workspace(context) else { return }
        let rootID = root.id.uuidString
        let sourceURL = root.url.appendingPathComponent(source, isDirectory: true)
        let targetURL = root.url.appendingPathComponent(target, isDirectory: true)
        status.phase = .consolidating
        status.directory = "\(source) → \(target)"
        progress(status)

        // Subfolders.
        let existing = Dictionary(Self.children(of: target, rootID: rootID, in: context).map { (ArchiveFileSystem.nameKey($0), $0) },
                                  uniquingKeysWith: { first, _ in first })
        var nested: [(String, String)] = []
        var moves: [ArchiveAIDirectoryRequest] = []
        for child in Self.children(of: source, rootID: rootID, in: context) {
            if let match = existing[ArchiveFileSystem.nameKey(child)] {
                nested.append((source + "/" + child, target + "/" + match))
            } else if !Self.isTaken(child, in: targetURL, by: sourceURL.appendingPathComponent(child)) {
                moves.append(ArchiveAIDirectoryRequest(action: .move, rootID: rootID, relativePath: target + "/" + child,
                                                       reason: reason, source: source + "/" + child))
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
            try await mergeFolder(from, into: to, depth: depth + 1, reason: reason, &summary, &status, progress)
        }

        // Files lying directly in the folder.
        let entries = (try? FileManager.default.contentsOfDirectory(at: sourceURL, includingPropertiesForKeys: [.isRegularFileKey],
                                                                     options: [.skipsHiddenFiles])) ?? []
        let paths = entries.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }.map(\.path).sorted()
        var taken = Set(((try? FileManager.default.contentsOfDirectory(atPath: targetURL.path)) ?? []).map(ArchiveFileSystem.nameKey))
        for start in stride(from: 0, to: paths.count, by: 30) {
            try Task.checkCancellation()
            context = try await service.prepareContext(paths: Array(paths[start..<min(start + 30, paths.count)]))
            let known = await service.snapshot().files ?? [:]
            var requests: [ArchiveAIFileRequest] = []
            var records: [String: ArchiveFileRecord] = [:]
            for file in context.files {
                let name = Self.uniqueName(file.source.lastPathComponent, taken: taken)
                taken.insert(ArchiveFileSystem.nameKey(name))
                requests.append(ArchiveAIFileRequest(fileID: file.id, rootID: file.rootID, relativeDirectory: target,
                                                     reason: reason, proposedName: name))
                if var record = known[file.source.path] {
                    if name != file.source.lastPathComponent { record.renamed = true }
                    records[file.source.path] = record
                }
            }
            guard !requests.isEmpty,
                  let applied = try await apply(ArchiveAIResponse(summary: "把「\(source)」并入「\(target)」", directories: [], files: requests),
                                                context: context, records: records, &status, progress) else { continue }
            let moved = applied.files.filter { $0.status == .complete }
            summary.movedFiles += moved.count
            summary.renamedFiles += moved.filter { $0.source.lastPathComponent != $0.destination.lastPathComponent }.count
            summary.batchIDs.append(applied.id)
            report(moved.map { operation in
                let renamed = operation.source.lastPathComponent != operation.destination.lastPathComponent
                return ArchiveFileActivity(path: operation.source.path, status: .completed,
                                           detail: "已并入「\(target)」" + (renamed ? "，同名文件改为 \(operation.destination.lastPathComponent)" : ""))
            })
        }

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

    // MARK: Step 1 – one file at a time

    private func reviewFiles(_ summary: inout ArchiveRunSummary, _ status: inout ArchiveRunProgress, _ progress: Progress) async throws {
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
            let context = try await service.prepareAIContext(limit: batchSize, keywordLimit: keywordLimit)
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
            // Strictly one after another: each file is reviewed, applied and recorded before the next starts.
            for (index, file) in context.files.enumerated() {
                do {
                    try Task.checkCancellation()
                    try await reviewFile(file, &summary, &status, progress)
                } catch is CancellationError {
                    report(context.files[index...].map { ArchiveFileActivity(path: $0.source.path, status: .queued, detail: "已停止，下次继续") })
                    throw CancellationError()
                } catch {
                    report([ArchiveFileActivity(path: file.source.path, status: .failed, detail: error.localizedDescription)])
                    report(context.files[(index + 1)...].map { ArchiveFileActivity(path: $0.source.path, status: .queued, detail: "下次继续") })
                    throw error
                }
                status.processedFiles += 1
                status.remainingFiles = max(0, status.remainingFiles - 1)
                progress(status)
            }
        }
    }

    /// Decides one file's place and name, applies the change, and records the result in the same commit.
    private func reviewFile(_ scanned: ArchiveAIFile, _ summary: inout ArchiveRunSummary,
                            _ status: inout ArchiveRunProgress, _ progress: Progress) async throws {
        let path = scanned.source.path
        report([ArchiveFileActivity(path: path, status: .processing, detail: "正在判断位置和名称")])
        status.phase = .reviewing
        status.directory = scanned.source.lastPathComponent
        status.batchFiles = 1
        status.receivedCharacters = 0
        progress(status)
        // A fresh snapshot for this file alone: the files before it may have changed the folders.
        let context = try await service.prepareFileContext(path: path, fingerprint: scanned.fingerprint, keywords: scanned.keywords)
        guard let file = context.files.first, let root = Self.workspace(context) else {
            report([ArchiveFileActivity(path: path, status: .queued, detail: "文件刚刚发生变化，下次重新处理")])
            return
        }
        let original = file.source.lastPathComponent
        let folder = (file.relativePath as NSString).deletingLastPathComponent
        let folders = context.directories.filter { $0.rootID == file.rootID && !$0.relativePath.isEmpty }.map(\.relativePath).sorted()
        let siblings = ((try? FileManager.default.contentsOfDirectory(atPath: file.source.deletingLastPathComponent().path)) ?? [])
            .filter { !$0.hasPrefix(".") && $0 != original }.sorted().prefix(20)

        var decision: ArchiveFileDecision?
        for attempt in 1...maxAttemptsPerRound {
            do {
                decision = try await planner.review(ArchiveFileReview(file: file, folder: folder, folders: folders, siblings: Array(siblings)))
                break
            } catch let error as ArchiveAIUnavailable {
                // The service, not the file, failed: one more try, then tell the user.
                guard attempt < maxAttemptsPerRound else { throw error }
            } catch where error is ArchiveError || error is DecodingError {
                // An unusable answer: ask once more, then leave the file as it is.
                guard attempt < maxAttemptsPerRound else { break }
            }
        }

        var record = ArchiveFileRecord(path: path, fingerprint: file.fingerprint, originalName: original,
                                       topic: Self.clean(decision?.topic, limit: 24), renamed: false,
                                       reason: Self.clean(decision?.reason, limit: 300), stage: .named)
        var name = original
        var target = folder
        var notes: [String] = []
        if let decision {
            if decision.proposedName != original {
                if let valid = try? ArchiveAINamePolicy.validate(decision.proposedName, original: file.source) { name = valid }
                else { notes.append("建议的名称不安全，保留原名") }
                record.suggestedName = Self.clean(decision.proposedName, limit: 240)
            }
            // Only a folder that already exists counts; new folders come from grouping related files later.
            let wanted = Self.clean(decision.folder, limit: 1_000).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !wanted.isEmpty, wanted != folder,
               let existing = folders.first(where: { ArchiveFileSystem.nameKey($0) == ArchiveFileSystem.nameKey(wanted) }),
               existing != folder {
                target = existing
            }
        }
        func url(_ relative: String) -> URL { relative.isEmpty ? root.url : root.url.appendingPathComponent(relative, isDirectory: true) }
        if target != folder, Self.isTaken(name, in: url(target), by: file.source) {
            target = folder
            notes.append("目标文件夹已有同名文件，留在原处")
        }
        if name != original, Self.isTaken(name, in: url(target), by: file.source) {
            name = original
            notes.append("新名称已被占用，保留原名")
        }
        if name != original { record.suggestedName = nil }
        if decision == nil { record.reason = "没有得到有效的结果，保留原名并留在原处" }
        else if !notes.isEmpty { record.reason = notes.joined(separator: "；") }
        let fits = decision?.belongsHere ?? !folder.isEmpty
        func settle(movedTo destination: String?) {
            if decision == nil {
                // Nothing was decided: retried when the folders change, never counted as organized.
                record.resolution = .unrecognized
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
        // Checked against this layout: an unresolved file is not offered again until the folders change.
        record.structure = context.structure

        guard name != original || target != folder else {
            try await service.saveFileRecords([record])
            report([ArchiveFileActivity(path: path, status: Self.activity(for: record), detail: Self.describe(record))])
            if decision == nil { summary.leftUntouched += 1 }
            return
        }
        record.renamed = name != original
        status.phase = .applying
        progress(status)
        let request = ArchiveAIFileRequest(fileID: file.id, rootID: file.rootID, relativeDirectory: target,
                                           reason: record.reason.isEmpty ? "位置或名称更合适" : record.reason, proposedName: name)
        let plan: ArchiveAIPlan
        do {
            plan = try await service.previewAI(ArchiveAIResponse(summary: "整理「\(original)」", directories: [], files: [request]),
                                               contextID: context.id, records: [path: record])
        } catch is ArchiveError {
            // The safety checks refused the change; record the file as it is instead.
            record.renamed = false
            if name != original { record.suggestedName = name }
            settle(movedTo: nil)
            record.reason = "更改未通过安全检查，保持原样"
            try await service.saveFileRecords([record])
            report([ArchiveFileActivity(path: path, status: Self.activity(for: record), detail: Self.describe(record))])
            return
        }
        // The move and the file's record are committed together.
        let applied = try await service.applyAI(plan.id)
        guard applied.status == .complete, let operation = applied.files.first, operation.status == .complete else {
            throw ArchiveNeedsReview(applied.error ?? "未能确认「\(original)」的更改，请在“整理记录”中核对。")
        }
        if record.renamed { summary.renamedFiles += 1 }
        if target != folder { summary.movedFiles += 1 }
        summary.batchIDs.append(applied.id)
        record.path = operation.destination.path
        report([ArchiveFileActivity(path: path, status: .completed,
                                    detail: Self.describe(record, movedTo: target != folder ? (target as NSString).lastPathComponent : nil))])
    }

    // MARK: Step 2 – files into folders

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
                })
                do {
                    groups = Self.validGroups(try await planner.group(request), files: context.files, subfolders: subfolders,
                                              folder: URL(fileURLWithPath: folder))
                } catch where error is ArchiveError || error is DecodingError {
                    leftReason = "没有得到有效的归类方案，保持不变"
                }
            }

            var created = false
            let assignments = groups.flatMap { group in group.files.map { (folder: group.folder, reason: group.reason, path: $0.source.path) } }
            // The service accepts at most 30 file moves per plan; each slice gets a fresh snapshot.
            for start in stride(from: 0, to: assignments.count, by: 30) {
                let slice = assignments[start..<min(start + 30, assignments.count)]
                let fresh = try await service.prepareRecordedContext(paths: slice.map(\.path))
                var directories: [ArchiveAIDirectoryRequest] = []
                var requests: [ArchiveAIFileRequest] = []
                var planRecords: [String: ArchiveFileRecord] = [:]
                for item in slice {
                    guard let file = fresh.files.first(where: { $0.source.path == item.path }), var record = byPath[item.path] else { continue }
                    let target = relative.isEmpty ? item.folder : relative + "/" + item.folder
                    if !fresh.directories.contains(where: { $0.rootID == file.rootID && $0.relativePath == target }),
                       !directories.contains(where: { $0.relativePath == target }) {
                        directories.append(ArchiveAIDirectoryRequest(action: .create, rootID: file.rootID, relativePath: target, reason: item.reason))
                    }
                    record.stage = .grouped
                    record.resolution = .organized
                    record.misplaced = nil
                    record.processedAt = Date()
                    planRecords[item.path] = record
                    requests.append(ArchiveAIFileRequest(fileID: file.id, rootID: file.rootID, relativeDirectory: target,
                                                         reason: item.reason, proposedName: file.source.lastPathComponent))
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
                summary.createdDirectories += made
                summary.batchIDs.append(applied.id)
                created = created || made > 0
                for operation in moved {
                    unfinished.remove(operation.source.path)
                    report([ArchiveFileActivity(path: operation.source.path, status: .completed,
                                                detail: "已归入「\(operation.destination.deletingLastPathComponent().lastPathComponent)」")])
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
                record.isResolved ? ArchiveFileActivity(path: record.path, status: .completed, detail: leftReason)
                    : ArchiveFileActivity(path: record.path, status: .unplaced, detail: Self.describe(record))
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
        var folder: String
        var files: [ArchiveAIFile]
        var reason: String
    }

    /// Keeps only groups that are safe and worth having: a valid single folder name, known files listed once,
    /// existing folders reused regardless of case, and no new folder for a single file.
    private static func validGroups(_ answer: ArchiveGroupingResponse, files: [ArchiveAIFile], subfolders: [String], folder: URL) -> [Group] {
        let byID = Dictionary(files.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var used = Set<String>()
        var names = Set<String>()
        var result: [Group] = []
        for group in answer.groups {
            let raw = group.folder.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
            guard ArchiveDirectoryFileSystem.isValidComponent(raw) else { continue }
            let existing = subfolders.first { ArchiveFileSystem.nameKey($0) == ArchiveFileSystem.nameKey(raw) }
            let name = existing ?? raw
            guard names.insert(ArchiveFileSystem.nameKey(name)).inserted else { continue }
            let destination = folder.appendingPathComponent(name, isDirectory: true)
            let members = group.fileIDs.compactMap { id -> ArchiveAIFile? in
                guard let file = byID[id], !used.contains(id) else { return nil }
                if existing != nil, isTaken(file.source.lastPathComponent, in: destination, by: file.source) { return nil }
                return file
            }
            guard members.count >= (existing == nil ? 2 : 1) else { continue }
            members.forEach { used.insert($0.id) }
            let reason = clean(group.reason, limit: 300)
            result.append(Group(folder: name, files: members, reason: reason.isEmpty ? "相关文件放在一起" : reason))
        }
        return result
    }

    // MARK: Step 3 – folder levels

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
    /// check whether the new folders group further.
    private func nestOnce(in folder: String, _ summary: inout ArchiveRunSummary,
                          _ status: inout ArchiveRunProgress, _ progress: Progress) async throws -> Bool {
        let context = try await service.prepareRecordedContext(paths: [])
        guard let root = Self.workspace(context), ArchiveFileSystem.contains(URL(fileURLWithPath: folder), in: root.url),
              FileManager.default.fileExists(atPath: folder) else { return false }
        let rootID = root.id.uuidString
        let relative = ArchiveDirectoryFileSystem.relativePath(URL(fileURLWithPath: folder), root: root.url)
        let names = Self.children(of: relative, rootID: rootID, in: context)
        guard names.count >= 3 else { return false }
        func path(_ name: String) -> String { relative.isEmpty ? name : relative + "/" + name }
        func subtreeDepth(_ name: String) -> Int {
            let prefix = path(name) + "/"
            return context.directories.filter { $0.rootID == rootID && $0.relativePath.hasPrefix(prefix) }
                .map { Self.depth($0.relativePath) - Self.depth(path(name)) }.max() ?? 0
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
        })
        let answer: ArchiveNestingResponse
        do { answer = try await planner.nest(request) }
        catch where error is ArchiveError || error is DecodingError { return false }

        let existing = Dictionary(names.map { (ArchiveFileSystem.nameKey($0), $0) }, uniquingKeysWith: { first, _ in first })
        var taken = Set(existing.keys)
        var used = Set<String>()
        var directories: [ArchiveAIDirectoryRequest] = []
        var addsLevel = false
        for group in answer.groups ?? [] {
            let name = group.folder.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
            guard ArchiveDirectoryFileSystem.isValidComponent(name), !taken.contains(ArchiveFileSystem.nameKey(name)) else { continue }
            let members = Set(group.children.compactMap { existing[ArchiveFileSystem.nameKey($0)] })
                .filter { !used.contains($0) && Self.depth(relative) + 2 + subtreeDepth($0) <= maxDepth }
                .sorted()
            // A new level must gather at least two folders and must not just wrap the whole level.
            guard members.count >= 2, members.count < names.count, directories.count + 1 + members.count <= 20 else { continue }
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
            let name = rename.to.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
            guard let from = existing[ArchiveFileSystem.nameKey(rename.from)], !used.contains(from),
                  ArchiveDirectoryFileSystem.isValidComponent(name), !taken.contains(ArchiveFileSystem.nameKey(name)),
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

    private static func isTaken(_ name: String, in folder: URL, by source: URL) -> Bool {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return entries.contains { $0 != source.lastPathComponent && ArchiveFileSystem.nameKey($0) == ArchiveFileSystem.nameKey(name) }
    }

    /// The name itself when free, otherwise `stem (2).ext`, `stem (3).ext`, … so nothing is overwritten.
    private static func uniqueName(_ name: String, taken: Set<String>) -> String {
        guard taken.contains(ArchiveFileSystem.nameKey(name)) else { return name }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        for number in 2...999 {
            let candidate = "\(stem) (\(number))" + (ext.isEmpty ? "" : "." + ext)
            if !taken.contains(ArchiveFileSystem.nameKey(candidate)) { return candidate }
        }
        return "\(stem) (\(UUID().uuidString.prefix(8)))" + (ext.isEmpty ? "" : "." + ext)
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
