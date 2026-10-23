import Foundation

/// Every folder of the workspace, from the top down, described by what is in it: its own name and its parents',
/// the kinds of files it holds, a few of their names and the topics already found for them. A file is compared
/// with all of them locally, and the closest few go to the model with this description, so the model chooses
/// between folders by their contents instead of by a bare list of names — and a good folder three levels deep is
/// found even when the file sits somewhere else entirely.
nonisolated struct ArchiveFolderCatalog: Sendable {
    struct Folder: Sendable {
        /// Relative to the workspace.
        var path: String
        var fileCount: Int
        var extensions: [String: Int]
        var samples: [String]
        var topics: [String]
        /// Words of the path's own names; a match here counts most.
        var nameTokens: Set<String>
        /// Words of the files and topics inside.
        var contentTokens: Set<String>
    }

    struct Candidate: Sendable {
        var folder: Folder
        var score: Double
    }

    var folders: [Folder]

    /// Reads each folder's direct files once. `records` supplies topics found by earlier reviews.
    static func build(root: URL, folders paths: [String], records: [String: ArchiveFileRecord], limit: Int = 600) -> ArchiveFolderCatalog {
        var topicsByFolder: [String: [String: Int]] = [:]
        let prefix = root.path + "/"
        for record in records.values where record.path.hasPrefix(prefix) && !record.topic.isEmpty {
            let folder = (String(record.path.dropFirst(prefix.count)) as NSString).deletingLastPathComponent
            topicsByFolder[folder, default: [:]][record.topic, default: 0] += 1
        }
        var result: [Folder] = []
        for path in ([""] + paths).prefix(limit) {
            let url = path.isEmpty ? root : root.appendingPathComponent(path, isDirectory: true)
            let entries = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                                                         options: [.skipsHiddenFiles])) ?? []
            let files = entries.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
                .map(\.lastPathComponent).sorted()
            var extensions: [String: Int] = [:]
            for name in files { extensions[(name as NSString).pathExtension.lowercased(), default: 0] += 1 }
            let topics = (topicsByFolder[path] ?? [:]).sorted { ($1.value, $0.key) < ($0.value, $1.key) }.map(\.key)
            var content = Set<String>()
            for name in files.prefix(200) { content.formUnion(ArchiveLearning.tokens((name as NSString).deletingPathExtension)) }
            for topic in topics { content.formUnion(ArchiveLearning.tokens(topic)) }
            result.append(Folder(path: path, fileCount: files.count, extensions: extensions, samples: Array(files.prefix(8)),
                                 topics: Array(topics.prefix(6)),
                                 nameTokens: ArchiveLearning.tokens(path.replacingOccurrences(of: "/", with: " ")), contentTokens: content))
        }
        return ArchiveFolderCatalog(folders: result)
    }

    /// The folders most like the file, best first. The workspace itself is never a candidate: a file is only
    /// left loose when nothing fits.
    func candidates(for file: ArchiveAIFile, limit: Int) -> [Candidate] {
        let name = file.source.lastPathComponent
        let ext = (name as NSString).pathExtension.lowercased()
        var tokens = ArchiveLearning.tokens((name as NSString).deletingPathExtension)
        tokens.formUnion(file.keywords.prefix(24))
        for key in ["title", "author", "album", "subject", "tags", "from", "kind"] {
            if let value = file.metadata?[key] { tokens.formUnion(ArchiveLearning.tokens(value)) }
        }
        let scored = folders.compactMap { folder -> Candidate? in
            guard !folder.path.isEmpty else { return nil }
            let byName = Double(tokens.intersection(folder.nameTokens).count)
            let byContent = Double(tokens.intersection(folder.contentTokens).count)
            let sameType = folder.fileCount > 0 ? Double(folder.extensions[ext] ?? 0) / Double(folder.fileCount) : 0
            var score = 3 * byName + min(byContent, 6) + 2 * sameType
            guard score > 0 else { return nil }
            // A deeper folder is more specific; between equals, prefer it.
            score += 0.1 * Double(folder.path.split(separator: "/").count)
            return Candidate(folder: folder, score: score)
        }
        return Array(scored.sorted { ($0.score, $1.folder.path) > ($1.score, $0.folder.path) }.prefix(max(0, limit)))
    }

    /// A best candidate convincing enough to place a file the model could not judge: a word of the folder's
    /// name, or several words of its files, in common with the file — not just the same extension.
    func confidentMatch(for file: ArchiveAIFile) -> Folder? {
        guard let best = candidates(for: file, limit: 1).first, best.score >= 3 else { return nil }
        return best.folder
    }

    func folder(_ path: String) -> Folder? { folders.first { $0.path == path } }
}
