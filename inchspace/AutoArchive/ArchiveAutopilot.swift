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

nonisolated enum ArchiveRunProgress: Equatable, Sendable {
    case scanning
    case planning(round: Int, files: Int)
    case applying(round: Int, files: Int)
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

    func run(progress: @MainActor (ArchiveRunProgress) -> Void = { _ in }) async throws -> ArchiveRunSummary {
        var summary = ArchiveRunSummary()
        var waits = 0
        var round = 0
        while true {
            try Task.checkCancellation()
            guard round < maxRounds else { summary.hasMore = true; break }
            progress(.scanning)
            let context = try await service.prepareAIContext()
            if context.files.isEmpty {
                // Newly seen files must hold still for a moment before they are touched.
                if context.unsettledCount > 0, waits < 3 {
                    waits += 1
                    try await Task.sleep(for: stableWait)
                    continue
                }
                break
            }
            waits = 0
            round += 1
            switch try await attempt(context, round: round, progress: progress) {
            case .done(let result):
                summary.movedFiles += result.movedFiles
                summary.createdDirectories += result.createdDirectories
                summary.removedDirectories += result.removedDirectories
                if let id = result.batchID { summary.batchIDs.append(id) }
            case .gaveUp:
                // The model could not produce a valid plan for these files; leave them where they are.
                try await service.markSettled(Dictionary(uniqueKeysWithValues: context.files.map { ($0.source.path, $0.fingerprint) }))
                summary.leftUntouched += context.files.count
            }
        }
        return summary
    }

    private enum Outcome {
        case done(RoundResult)
        case gaveUp
    }

    private struct RoundResult {
        var movedFiles = 0
        var createdDirectories = 0
        var removedDirectories = 0
        var batchID: UUID?
    }

    private func attempt(_ first: ArchiveAIContext, round: Int, progress: @MainActor (ArchiveRunProgress) -> Void) async throws -> Outcome {
        var context = first
        for attempt in 1...maxAttemptsPerRound {
            try Task.checkCancellation()
            progress(.planning(round: round, files: context.files.count))
            do {
                let response = try await planner(context)
                let plan = try await service.previewAI(response, contextID: context.id)
                var result = RoundResult()
                var settled: [String: ArchiveFingerprint] = [:]
                var removedPaths: [String] = []
                if plan.directories.isEmpty && plan.files.isEmpty {
                    // Nothing to improve: remember that, so the same files are not sent again.
                    for file in context.files { settled[file.source.path] = file.fingerprint }
                } else {
                    progress(.applying(round: round, files: plan.files.count))
                    let applied = try await service.applyAI(plan.id)
                    guard applied.status == .complete else {
                        throw ArchiveNeedsReview(applied.error ?? "部分文件未能确认移动，请在“历史”中核对。")
                    }
                    let moved = Set(applied.files.filter { $0.status == .complete }.map(\.source.path))
                    for file in context.files where !moved.contains(file.source.path) { settled[file.source.path] = file.fingerprint }
                    for operation in applied.files where operation.status == .complete {
                        settled[operation.destination.path] = operation.fingerprint
                        removedPaths.append(operation.source.path)
                    }
                    result.movedFiles = moved.count
                    result.createdDirectories = applied.directories.filter { $0.action == .create && $0.status == .complete }.count
                    result.removedDirectories = applied.directories.filter { $0.action == .removeEmpty && $0.status == .complete }.count
                    result.batchID = applied.id
                }
                try await service.markSettled(settled, removing: removedPaths)
                return .done(result)
            } catch let error as ArchiveNeedsReview {
                // A half-finished plan is never retried automatically.
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch where error is ArchiveError || error is DecodingError {
                // The model's plan failed local validation; ask again once with a fresh snapshot.
                guard attempt < maxAttemptsPerRound else { return .gaveUp }
                context = try await service.prepareAIContext()
                if context.files.isEmpty { return .done(RoundResult()) }
            }
        }
        return .gaveUp
    }
}
