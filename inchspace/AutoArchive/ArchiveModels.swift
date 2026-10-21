import Foundation

nonisolated enum ArchiveFolderRole: String, Codable, CaseIterable, Identifiable, Sendable {
    case inbox, library, excluded
    /// One folder that is both the place files arrive and the place they are organized into.
    case workspace
    var id: String { rawValue }
    var title: String {
        switch self {
        case .workspace: "整理目录"
        case .inbox: "待整理目录"
        case .library: "归档资料库"
        case .excluded: "排除目录"
        }
    }
}

nonisolated struct ArchiveFolder: Codable, Identifiable, Sendable {
    var id = UUID()
    var role: ArchiveFolderRole
    var url: URL
    var bookmark: Data?
    var directoryPermission: ArchiveDirectoryPermission?
}

nonisolated struct ArchiveConfiguration: Codable, Sendable {
    var folders: [ArchiveFolder] = []
    var stableSeconds: TimeInterval = 2
    var sampleLimit = 100
    var maxFileBytes = 20_000_000
    var inboxes: [URL] { folders.filter { $0.role == .inbox || $0.role == .workspace }.map(\.url) }
    var libraries: [URL] { folders.filter { $0.role == .library || $0.role == .workspace }.map(\.url) }
    var exclusions: [URL] { folders.filter { $0.role == .excluded }.map(\.url) }
}

nonisolated struct ArchiveFingerprint: Codable, Equatable, Sendable {
    var device: Int32
    var inode: UInt64
    var size: Int64
    var modifiedSeconds: Int64
    var modifiedNanoseconds: Int64
    var sha256: String
}

nonisolated struct ArchiveEvidence: Codable, Equatable, Sendable {
    var url: URL
    var fingerprint: ArchiveFingerprint
    var words: [String]
    var extractionNote: String?
}

nonisolated struct ArchiveRule: Codable, Identifiable, Sendable {
    var id: String { directory.path }
    var directory: URL
    var aliases: [String]
    var keywords: [String]
    var extensions: [String: Int]
    var evidence: [ArchiveEvidence]
    var confirmed = false
    var title: String { directory.lastPathComponent }
}

nonisolated enum ArchiveSuggestionStatus: String, Codable, Sendable {
    case pending, skipped, stale, applied
}

nonisolated struct ArchiveSuggestion: Codable, Identifiable, Sendable {
    var id = UUID()
    var source: URL
    var fingerprint: ArchiveFingerprint
    var directory: URL?
    var proposedName: String
    var reason: String
    var executable: Bool
    var extractionNote: String?
    var version: Int
    var createdAt = Date()
    var status: ArchiveSuggestionStatus = .pending
}

nonisolated enum ArchiveApplyMode: String, CaseIterable, Identifiable, Sendable {
    case both, move, rename
    var id: String { rawValue }
    var title: String {
        switch self {
        case .both: "移动并规范命名"
        case .move: "仅移动"
        case .rename: "仅规范命名"
        }
    }
    func destination(for suggestion: ArchiveSuggestion) -> URL? {
        let parent = self == .rename ? suggestion.source.deletingLastPathComponent() : suggestion.directory
        let name = self == .move ? suggestion.source.lastPathComponent : suggestion.proposedName
        return parent?.appendingPathComponent(name)
    }
}

nonisolated enum ArchiveOperationStatus: String, Codable, Sendable {
    case planned, complete, undoPlanned, undone, notExecuted, needsReview
    var title: String {
        switch self {
        case .planned: "等待执行"
        case .complete: "已完成"
        case .undoPlanned: "等待撤销"
        case .undone: "已撤销"
        case .notExecuted: "未执行"
        case .needsReview: "需要检查"
        }
    }
}

nonisolated struct ArchiveOperation: Codable, Identifiable, Sendable {
    var id = UUID()
    var suggestionID: UUID
    var source: URL
    var destination: URL
    var fingerprint: ArchiveFingerprint
    var staging: URL
    var undoStaging: URL
    var createdAt = Date()
    var status: ArchiveOperationStatus = .planned
    var undoRequested = false
    var error: String?
    var reason: String?
    // Nil preserves legacy inbox-origin operations. AI reorganization can also originate in a library.
    var sourceRole: ArchiveFolderRole?
}

nonisolated struct ArchiveObservation: Codable, Sendable {
    var fingerprint: ArchiveFingerprint
    var firstSeen: Date
}

nonisolated struct ArchiveLearningReport: Codable, Sendable {
    var sampled: Int
    var extractionFailures: Int
    var cached: Int
    var heldOut: Int
    var consistent: Int
    var learnedAt = Date()
}

nonisolated struct ArchiveState: Codable, Sendable {
    var configuration = ArchiveConfiguration()
    var version = 0
    var rules: [ArchiveRule] = []
    var suggestions: [ArchiveSuggestion] = []
    var operations: [ArchiveOperation] = []
    var observations: [String: ArchiveObservation] = [:]
    var cache: [String: ArchiveEvidence] = [:]
    var report: ArchiveLearningReport?
    var ai: ArchiveAIState?
    /// Files already reviewed by autopilot, keyed by path; a changed fingerprint makes a file eligible again.
    var settled: [String: ArchiveFingerprint]?
}

nonisolated struct ArchiveScanResult: Sendable {
    var files: [ArchiveEvidence] = []
    var warnings: [String] = []
}

nonisolated struct ArchiveError: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
