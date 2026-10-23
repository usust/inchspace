import Foundation

nonisolated struct ArchiveDirectoryPermission: Codable, Equatable, Sendable {
    var canCreate = false
    var canRemoveEmpty = false
}

nonisolated enum ArchiveDirectoryActionKind: String, Codable, Sendable {
    case create, removeEmpty
    /// Moves or renames a whole folder in one exclusive rename; its contents keep their identity.
    case move
    var title: String {
        switch self {
        case .create: "新建目录"
        case .removeEmpty: "删除空目录"
        case .move: "移动目录"
        }
    }
    /// Order inside a plan: parents first, then folder moves, then cleanup.
    var order: Int {
        switch self {
        case .create: 0
        case .move: 1
        case .removeEmpty: 2
        }
    }
}

nonisolated struct ArchiveDirectoryIdentity: Codable, Equatable, Sendable {
    var device: Int32
    var inode: UInt64
    var permissions: UInt16
}

nonisolated struct ArchiveAIDirectory: Codable, Sendable {
    var rootID: String
    var relativePath: String
    var identity: ArchiveDirectoryIdentity
    var isEmpty: Bool
}

nonisolated struct ArchiveAIFile: Codable, Sendable {
    var id: String
    var rootID: String
    var relativePath: String
    var source: URL
    var fingerprint: ArchiveFingerprint
    var keywords: [String]
}

nonisolated struct ArchiveAIContext: Codable, Sendable {
    var id = UUID()
    var version: Int
    var createdAt = Date()
    var folders: [ArchiveFolder]
    var directories: [ArchiveAIDirectory]
    var files: [ArchiveAIFile]
    var warnings: [String]
    /// Files seen for the first time or still changing; they become eligible once stable.
    var unsettledCount = 0
    /// Stable files that did not fit into this batch and will be offered in a later round.
    var pendingCount = 0
    /// A digest of the folder layout at scan time; see `ArchiveFileRecord.structure`.
    var structure = ""
}

nonisolated struct ArchiveAIDirectoryRequest: Codable, Sendable {
    var action: ArchiveDirectoryActionKind
    var rootID: String
    var relativePath: String
    var reason: String
    /// For `move`: the folder being moved, relative to the same root.
    var source: String? = nil
}

nonisolated struct ArchiveAIFileRequest: Codable, Sendable {
    var fileID: String
    var rootID: String
    var relativeDirectory: String
    var reason: String
    var proposedName: String? = nil
}

nonisolated struct ArchiveAIResponse: Codable, Sendable {
    var summary: String
    var directories: [ArchiveAIDirectoryRequest]
    var files: [ArchiveAIFileRequest]
}

nonisolated struct ArchiveDirectoryOperation: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var action: ArchiveDirectoryActionKind
    var rootID: String
    var target: URL
    var reason: String
    var originalIdentity: ArchiveDirectoryIdentity?
    var resultingIdentity: ArchiveDirectoryIdentity?
    var status: ArchiveOperationStatus = .planned
    var error: String?
    /// For `move`: where the folder was before.
    var source: URL?
}

nonisolated struct ArchiveAIPlan: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var contextID: UUID
    var version: Int
    var createdAt = Date()
    var summary: String
    var directories: [ArchiveDirectoryOperation]
    var files: [ArchiveOperation]
    var status: ArchiveOperationStatus = .planned
    var error: String?
    /// Results to save for each file, keyed by source path; written in the same commit as the file's move.
    var records: [String: ArchiveFileRecord]?
}

nonisolated struct ArchiveAIState: Codable, Sendable {
    var plans: [ArchiveAIPlan] = []
}

extension ArchiveAIPlan {
    nonisolated func targetTree(folders: [ArchiveFolder]) -> String {
        var lines: [String] = []
        for folder in folders.filter({ $0.role == .library || $0.role == .workspace }).sorted(by: { $0.url.path < $1.url.path }) {
            let paths = files.filter { ArchiveFileSystem.contains($0.destination, in: folder.url) }.map {
                ArchiveDirectoryFileSystem.relativePath($0.destination, root: folder.url).split(separator: "/").map(String.init)
            }
            guard !paths.isEmpty else { continue }
            lines.append(folder.url.lastPathComponent + "/")
            func appendNodes(_ paths: [[String]], prefix: String) {
                let names = Set(paths.compactMap(\.first)).sorted()
                for (index, name) in names.enumerated() {
                    let last = index == names.count - 1
                    let descendants = paths.filter { $0.first == name && $0.count > 1 }.map { Array($0.dropFirst()) }
                    lines.append(prefix + (last ? "└─ " : "├─ ") + name + (descendants.isEmpty ? "" : "/"))
                    if !descendants.isEmpty { appendNodes(descendants, prefix: prefix + (last ? "   " : "│  ")) }
                }
            }
            appendNodes(paths, prefix: "")
        }
        return lines.joined(separator: "\n")
    }
}
