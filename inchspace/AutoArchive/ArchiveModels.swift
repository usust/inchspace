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

    /// Same file, same size, same modification time: treated as unchanged without reading the content.
    func sameMetadata(_ other: ArchiveFingerprint) -> Bool {
        device == other.device && inode == other.inode && size == other.size &&
            modifiedSeconds == other.modifiedSeconds && modifiedNanoseconds == other.modifiedNanoseconds
    }

    /// Survives renames and moves on the same volume; used to find a record again after the file moved.
    var identityKey: String { "\(device):\(inode):\(size):\(modifiedSeconds).\(modifiedNanoseconds)" }
}

nonisolated struct ArchiveEvidence: Codable, Equatable, Sendable {
    var url: URL
    var fingerprint: ArchiveFingerprint
    var words: [String]
    var extractionNote: String?
}

nonisolated struct ArchiveRule: Codable, Equatable, Identifiable, Sendable {
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

nonisolated struct ArchiveSuggestion: Codable, Equatable, Identifiable, Sendable {
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

nonisolated struct ArchiveOperation: Codable, Equatable, Identifiable, Sendable {
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

nonisolated struct ArchiveObservation: Codable, Equatable, Sendable {
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

nonisolated enum ArchiveFileStage: String, Codable, Sendable {
    /// The file was reviewed on its own; it still waits to be grouped with related files.
    case named
    /// Grouping is done for this file.
    case grouped
}

/// Where a reviewed file stands. Only `organized` files are left alone for good while unchanged.
nonisolated enum ArchiveFileResolution: String, Codable, Sendable {
    /// In a folder where it belongs.
    case organized
    /// Reviewed, but no clear destination yet (loose in the workspace, or not fitting its folder).
    case unplaced
    /// The review itself failed; nothing was decided.
    case unrecognized
}

/// What autopilot decided about one file. Saved as soon as the decision is final, so an interrupted run
/// resumes where it stopped and an unchanged file is never sent to the model twice.
nonisolated struct ArchiveFileRecord: Codable, Equatable, Sendable {
    var path: String
    var fingerprint: ArchiveFingerprint
    var originalName: String
    /// A few words on what the file is about, used to group it with related files.
    var topic: String
    var renamed: Bool
    var reason: String
    var stage: ArchiveFileStage
    var processedAt = Date()
    /// Nil in records from before resolutions existed; those count as organized.
    var resolution: ArchiveFileResolution?
    /// The folder layout an unresolved file was last reviewed against. When the layout or the workspace
    /// changes, the file is reviewed again even though it did not change itself.
    var structure: String?
    /// A better name the model suggested but that could not be applied (unsafe or taken); kept for review.
    var suggestedName: String?
    /// Reviewed as not belonging to the folder it is in; it joins the loose files when grouping.
    var misplaced: Bool?
    /// One sentence on what the file is, from the model.
    var summary: String?
    /// The file's creation time (birth time), seconds since 1970; nil when the volume does not report one.
    var createdSeconds: Int64?
    /// The folder the file was in before autopilot moved it, relative to the workspace; nil when it never moved.
    var previousFolder: String?
    /// The journal entry that moved or renamed the file, so that one change can be undone on its own.
    var operationID: UUID?

    var isResolved: Bool { (resolution ?? .organized) == .organized }
    var createdAt: Date? { createdSeconds.map { Date(timeIntervalSince1970: TimeInterval($0)) } }
    var modifiedAt: Date { Date(timeIntervalSince1970: TimeInterval(fingerprint.modifiedSeconds)) }
    var size: Int64 { fingerprint.size }
    var name: String { (path as NSString).lastPathComponent }
    var wasRenamed: Bool { renamed && name != originalName }

    /// The reason earlier versions saved when the model gave no usable answer. Those files were left as they
    /// were without any judgment, so they are looked at once more with the fuller evidence sent now.
    static let legacyNoAnswerReason = "没有得到有效的结果，保留原名并留在原处"

    /// Whether a run should look at this unchanged file again.
    func needsReview(structure current: String) -> Bool {
        if resolution == .unrecognized && reason == Self.legacyNoAnswerReason { return true }
        return !isResolved && structure != current
    }
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
    /// Per-file results keyed by current path. A record whose fingerprint still matches is not reprocessed.
    var files: [String: ArchiveFileRecord]?
    /// What the convention knows about each folder, keyed by absolute path: its category and naming pattern.
    var folders: [String: ArchiveFolderRecord]?
    /// The last structure audit; decides whether the next run audits the folder tree again.
    var audit: ArchiveAuditState?
    /// The local consistency check after the last run; its open items are handled first next time.
    var consistency: ArchiveConsistencyReport?
    /// The user's organizing preference in plain words; read as overrides of the convention.
    var preference: String?

    /// The convention every stage works under: the standard one with the user's preference applied.
    var convention: ArchiveConvention { ArchiveConvention.parse(preference: preference ?? "") }

    /// Whether this run starts with a structure audit: the folder layout changed, the last audit failed, or it left
    /// items open that have not yet had three tries.
    func needsAudit(structure: String) -> Bool {
        guard let audit else { return true }
        switch audit.status {
        case .failed: return true
        case .incomplete: return audit.structure != structure || audit.attempts < ArchiveAuditState.maxAttempts
        case .complete: return audit.structure != structure
        }
    }
}

/// What the convention knows about one folder. The naming pattern is derived the first time the folder is organized
/// and kept from then on, so every later file follows the same pattern instead of each batch inventing one.
nonisolated struct ArchiveFolderRecord: Codable, Equatable, Sendable {
    /// Absolute path.
    var path: String
    /// The dictionary category the folder holds (`ArchiveCategory.id`); nil for a project or an unknown folder.
    var category: String?
    /// True when the audit found the folder to be a project rather than a category.
    var isProject: Bool?
    var pattern: ArchiveNamingPattern?
    var auditedAt: Date?
    /// Share of the folder's own files that belong where they are, 0...1, from the last audit.
    var purity: Double?
}

nonisolated struct ArchiveAuditState: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        case complete
        /// The audit ran, but some folders or names still do not follow the convention.
        case incomplete
        /// The model could not be asked; only the dictionary's local decisions were applied.
        case failed
    }

    /// Open items stop forcing a new audit after this many runs that could not settle them.
    static let maxAttempts = 3

    /// The folder layout the audit settled, as `ArchiveDirectoryFileSystem.signature`.
    var structure: String
    var status: Status
    var message: String?
    var finishedAt = Date()
    /// Consecutive runs that ended with open items.
    var attempts = 0
}

/// The local check after every run: no request to the model, only the convention applied to what is on disk.
nonisolated struct ArchiveConsistencyReport: Codable, Equatable, Sendable {
    struct Issue: Codable, Equatable, Identifiable, Sendable {
        enum Kind: String, Codable, Sendable {
            /// Two or more folders hold the same category.
            case duplicateCategory
            /// A category folder that is not at the category's canonical path.
            case misplacedCategory
            /// A folder name that breaks the directory convention.
            case folderName
            /// A file name that does not follow its folder's naming pattern.
            case fileName
        }

        var kind: Kind
        /// Relative to the workspace.
        var path: String
        var detail: String
        var id: String { kind.rawValue + ":" + path }
    }

    var checkedAt = Date()
    var issues: [Issue] = []
    /// File-name issues beyond the ones listed; the list is capped to keep the record small.
    var omittedFileIssues = 0

    var isClean: Bool { issues.isEmpty }

    func count(_ kind: Issue.Kind) -> Int {
        issues.filter { $0.kind == kind }.count + (kind == .fileName ? omittedFileIssues : 0)
    }

    var summary: String {
        guard !isClean else { return "目录与命名都符合规范" }
        var parts: [String] = []
        let duplicates = count(.duplicateCategory) + count(.misplacedCategory)
        if duplicates > 0 { parts.append("\(duplicates) 个类别文件夹不唯一或不在规范位置") }
        if count(.folderName) > 0 { parts.append("\(count(.folderName)) 个文件夹名不规范") }
        if count(.fileName) > 0 { parts.append("\(count(.fileName)) 个文件名不符合所在文件夹的模式") }
        return parts.joined(separator: "，")
    }
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
