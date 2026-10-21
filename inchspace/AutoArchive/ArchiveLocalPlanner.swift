import Foundation

/// Offline planner used when no AI model is available. It produces the same response type as the model,
/// so every plan still goes through the service's validation and journaling before anything moves.
/// It only tidies files lying directly in the folder and never renames anything.
nonisolated enum ArchiveLocalPlanner {
    private static let categories: [(name: String, extensions: Set<String>)] = [
        ("图片", ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tiff", "bmp", "svg", "raw", "psd"]),
        ("文档", ["pdf", "doc", "docx", "txt", "md", "rtf", "pages", "epub", "odt"]),
        ("表格", ["xls", "xlsx", "csv", "numbers", "tsv"]),
        ("演示文稿", ["ppt", "pptx", "key"]),
        ("压缩包", ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz"]),
        ("安装包", ["dmg", "pkg", "iso"]),
        ("音频", ["mp3", "wav", "aac", "flac", "m4a", "aiff", "ogg"]),
        ("视频", ["mp4", "mov", "mkv", "avi", "m4v", "webm"]),
    ]

    static func category(forExtension ext: String) -> String? {
        let lower = ext.lowercased()
        return categories.first { $0.extensions.contains(lower) }?.name
    }

    static func plan(_ context: ArchiveAIContext) -> ArchiveAIResponse {
        guard let root = context.folders.first(where: { $0.role == .workspace }) else {
            return ArchiveAIResponse(summary: "没有可整理的目录。", directories: [], files: [])
        }
        let rootID = root.id.uuidString
        let existing = context.directories.filter { $0.rootID == rootID && !$0.relativePath.isEmpty }.map(\.relativePath)
        let existingKeys = Set(existing.map(ArchiveFileSystem.nameKey))
        var creates: [String] = []
        var files: [ArchiveAIFileRequest] = []
        var claimed = Set<String>()

        for file in context.files where file.rootID == rootID && !file.relativePath.contains("/") {
            let name = file.source.lastPathComponent
            let stem = (name as NSString).deletingPathExtension.lowercased()
            let keywords = Set(file.keywords.map { $0.lowercased() })
            // 1. A folder the user already made whose name appears in the file's name or keywords.
            let named = existing.filter { path in
                let leaf = (path as NSString).lastPathComponent.lowercased()
                return leaf.count >= 2 && (stem.contains(leaf) || keywords.contains(leaf))
            }.max { $0.count < $1.count }
            // 2. Otherwise a folder for the kind of file.
            var directory = named
            var reason = "文件名与已有文件夹「\(named.map { ($0 as NSString).lastPathComponent } ?? "")」匹配。"
            if directory == nil, let kind = category(forExtension: file.source.pathExtension) {
                directory = existing.first { ArchiveFileSystem.nameKey($0) == ArchiveFileSystem.nameKey(kind) } ?? kind
                reason = "按文件类型归入「\(kind)」。"
            }
            guard let directory else { continue }
            let target = directory + "/" + name
            // Never aim at a name that is already taken in this batch or on disk.
            guard claimed.insert(ArchiveFileSystem.nameKey(target)).inserted,
                  !destinationExists(root: root.url, directory: directory, name: name) else { continue }
            if !existingKeys.contains(ArchiveFileSystem.nameKey(directory)),
               !creates.contains(where: { ArchiveFileSystem.nameKey($0) == ArchiveFileSystem.nameKey(directory) }) {
                creates.append(directory)
            }
            files.append(ArchiveAIFileRequest(fileID: file.id, rootID: rootID, relativeDirectory: directory,
                                              reason: reason, proposedName: name))
        }
        let directories = creates.map {
            ArchiveAIDirectoryRequest(action: .create, rootID: rootID, relativePath: $0, reason: "存放同类文件。")
        }
        return ArchiveAIResponse(summary: files.isEmpty ? "没有需要整理的文件。" : "按已有文件夹和文件类型在本机整理，未发送任何数据。",
                                 directories: directories, files: files)
    }

    private static func destinationExists(root: URL, directory: String, name: String) -> Bool {
        let url = directory.split(separator: "/").reduce(root) { $0.appendingPathComponent(String($1), isDirectory: true) }
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return false }
        return entries.contains { ArchiveFileSystem.nameKey($0) == ArchiveFileSystem.nameKey(name) }
    }
}
