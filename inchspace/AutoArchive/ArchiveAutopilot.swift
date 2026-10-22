import Foundation

nonisolated struct ArchiveRunSummary: Equatable, Sendable {
    var movedFiles = 0
    var createdDirectories = 0
    var removedDirectories = 0
    var leftUntouched = 0
    var batchIDs: [UUID] = []
    /// True when the round limit stopped the run before the folder was fully reviewed.
    var hasMore = false

    var isEmpty: Bool { movedFiles == 0 && createdDirectories == 0 && removedDirectories == 0 }
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
        /// New files must hold still briefly before they are touched.
        case waitingForStableFiles
        case planning
        case applying
    }

    var phase: Phase = .scanning
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

/// Runs the whole organize cycle without user decisions: scan, plan with the model, validate, apply, remember.
/// Safety checks stay in `ArchiveService`; autopilot only sequences them and never bypasses them.
@MainActor
struct ArchiveAutopilot {
    typealias Planner = @MainActor (ArchiveAIContext) async throws -> ArchiveAIResponse

    let service: ArchiveService
    let planner: Planner
    var stableWait: Duration = .milliseconds(2_300)
    var maxRounds = 60
    var maxAttemptsPerRound = 2
    /// Files per planning round; a slow local model gets fewer so each answer stays short.
    var batchSize = 30
    var keywordLimit = 80
    /// Receives per-file status changes as the run moves through each batch.
    var report: @MainActor ([ArchiveFileActivity]) -> Void = { _ in }

    func run(progress: @MainActor (ArchiveRunProgress) -> Void = { _ in }) async throws -> ArchiveRunSummary {
        var summary = ArchiveRunSummary()
        var status = ArchiveRunProgress()
        var waits = 0
        var round = 0
        while true {
            try Task.checkCancellation()
            guard round < maxRounds else { summary.hasMore = true; break }
            status.phase = .scanning
            status.batchFiles = 0
            status.receivedCharacters = 0
            progress(status)
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
                break
            }
            waits = 0
            round += 1
            status.round = round
            let outcome: Outcome
            do {
                outcome = try await attempt(context, status: &status, progress: progress)
            } catch is CancellationError {
                report(context.files.map { ArchiveFileActivity(path: $0.source.path, status: .queued, detail: "已停止，下次继续") })
                throw CancellationError()
            } catch {
                report(context.files.map { ArchiveFileActivity(path: $0.source.path, status: .failed, detail: error.localizedDescription) })
                throw error
            }
            switch outcome {
            case .done(let result):
                summary.movedFiles += result.movedFiles
                summary.createdDirectories += result.createdDirectories
                summary.removedDirectories += result.removedDirectories
                if let id = result.batchID { summary.batchIDs.append(id) }
                status.processedFiles += result.reviewedFiles
            case .gaveUp(let context):
                // The model could not produce a valid plan for these files; leave them where they are.
                try await service.markSettled(Dictionary(uniqueKeysWithValues: context.files.map { ($0.source.path, $0.fingerprint) }))
                report(context.files.map { ArchiveFileActivity(path: $0.source.path, status: .skipped, detail: "没有得到有效的归类方案，保持原位") })
                summary.leftUntouched += context.files.count
                status.processedFiles += context.files.count
            }
            status.remainingFiles = max(0, status.remainingFiles - status.batchFiles)
            progress(status)
        }
        return summary
    }

    private enum Outcome {
        case done(RoundResult)
        case gaveUp(ArchiveAIContext)
    }

    private struct RoundResult {
        var movedFiles = 0
        var createdDirectories = 0
        var removedDirectories = 0
        var reviewedFiles = 0
        var batchID: UUID?
    }

    private func attempt(_ first: ArchiveAIContext, status: inout ArchiveRunProgress,
                         progress: @MainActor (ArchiveRunProgress) -> Void) async throws -> Outcome {
        var context = first
        for attempt in 1...maxAttemptsPerRound {
            try Task.checkCancellation()
            status.phase = .planning
            status.batchFiles = context.files.count
            status.receivedCharacters = 0
            progress(status)
            let current = Set(context.files.map(\.source.path))
            report(first.files.filter { !current.contains($0.source.path) }
                .map { ArchiveFileActivity(path: $0.source.path, status: .queued, detail: "稍后分批处理") }
                + context.files.map { ArchiveFileActivity(path: $0.source.path, status: .processing) })
            do {
                let response = try await planner(context)
                let plan = try await service.previewAI(response, contextID: context.id)
                var result = RoundResult()
                var settled: [String: ArchiveFingerprint] = [:]
                var removedPaths: [String] = []
                var moves: [String: ArchiveOperation] = [:]
                result.reviewedFiles = context.files.count
                if plan.directories.isEmpty && plan.files.isEmpty {
                    // Nothing to improve: remember that, so the same files are not sent again.
                    for file in context.files { settled[file.source.path] = file.fingerprint }
                } else {
                    status.phase = .applying
                    progress(status)
                    let applied = try await service.applyAI(plan.id)
                    guard applied.status == .complete else {
                        throw ArchiveNeedsReview(applied.error ?? "部分文件未能确认移动，请在“历史”中核对。")
                    }
                    let moved = Set(applied.files.filter { $0.status == .complete }.map(\.source.path))
                    for file in context.files where !moved.contains(file.source.path) { settled[file.source.path] = file.fingerprint }
                    for operation in applied.files where operation.status == .complete {
                        moves[operation.source.path] = operation
                        settled[operation.destination.path] = operation.fingerprint
                        removedPaths.append(operation.source.path)
                    }
                    result.movedFiles = moved.count
                    result.createdDirectories = applied.directories.filter { $0.action == .create && $0.status == .complete }.count
                    result.removedDirectories = applied.directories.filter { $0.action == .removeEmpty && $0.status == .complete }.count
                    result.batchID = applied.id
                }
                try await service.markSettled(settled, removing: removedPaths)
                report(context.files.map { file in
                    ArchiveFileActivity(path: file.source.path, status: .completed,
                                        detail: moves[file.source.path].map(Self.describe) ?? "已记录，保持原位")
                })
                return .done(result)
            } catch let error as ArchiveNeedsReview {
                // A half-finished plan is never retried automatically.
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ArchiveAIUnavailable {
                // The service, not the plan, failed: one more try with half the files, then tell the user.
                guard attempt < maxAttemptsPerRound else { throw error }
                context = try await service.prepareAIContext(limit: max(3, context.files.count / 2), keywordLimit: min(keywordLimit, 40))
                if context.files.isEmpty { return .done(RoundResult()) }
            } catch where error is ArchiveError || error is DecodingError {
                // The model's plan failed local validation or was cut short; ask again once with a fresh,
                // smaller snapshot so a slow model has less to read and less to write.
                guard attempt < maxAttemptsPerRound else { return .gaveUp(context) }
                context = try await service.prepareAIContext(limit: max(3, context.files.count / 2), keywordLimit: min(keywordLimit, 40))
                if context.files.isEmpty { return .done(RoundResult()) }
            }
        }
        return .gaveUp(context)
    }

    private static func describe(_ move: ArchiveOperation) -> String {
        let folder = move.destination.deletingLastPathComponent().lastPathComponent
        let renamed = move.destination.lastPathComponent != move.source.lastPathComponent
        return renamed ? "已归入“\(folder)”，并重命名为 \(move.destination.lastPathComponent)" : "已归入“\(folder)”"
    }
}
