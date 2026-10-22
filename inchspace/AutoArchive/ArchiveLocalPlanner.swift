import Foundation

/// Offline planner used when no AI model is available. It answers the same questions as the model, so every
/// change still goes through the service's validation and journaling before anything moves. It never renames,
/// only groups files lying directly in the workspace, and leaves the folder levels alone.
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

    /// Names that clearly mean the same category. Only exact matches (ignoring case) count; anything vaguer is
    /// left to the model.
    private static let equivalents: [[String]] = [
        ["音乐", "music", "musics", "songs", "歌曲"],
        ["音频", "audio"],
        ["图片", "images", "pictures", "pics", "图像"],
        ["照片", "photos", "photo", "相片"],
        ["视频", "videos", "video"],
        ["电影", "movies", "films"],
        ["文档", "documents", "docs", "document"],
        ["表格", "spreadsheets", "sheets"],
        ["演示文稿", "presentations", "slides", "幻灯片"],
        ["压缩包", "archives", "compressed"],
        ["安装包", "installers"],
        ["截图", "屏幕截图", "screenshots", "screen shots"],
        ["壁纸", "wallpapers", "wallpaper"],
        ["下载", "downloads"],
        ["发票", "invoices", "invoice"],
        ["合同", "contracts", "contract"],
        ["简历", "resumes", "resume", "cv"],
        ["电子书", "ebooks", "e-books", "books"],
        ["字体", "fonts"],
    ]

    static func equivalenceClass(of name: String) -> Int? {
        let key = ArchiveFileSystem.nameKey(name)
        return equivalents.firstIndex { $0.contains { ArchiveFileSystem.nameKey($0) == key } }
    }

    /// Merges folders whose names mean the same category. The folder kept is a top-level one; the others must
    /// sit at most one level below a top-level folder, so a project's own subfolders are never pulled out.
    static func consolidate(_ request: ArchiveConsolidationRequest) -> ArchiveConsolidationResponse {
        func depth(_ path: String) -> Int { path.split(separator: "/").count }
        let classes = Dictionary(grouping: request.folders.filter { depth($0.path) <= 2 }) {
            equivalenceClass(of: ($0.path as NSString).lastPathComponent) ?? -1
        }
        var merges: [ArchiveConsolidationResponse.Merge] = []
        for (index, folders) in classes where index >= 0 && folders.count > 1 {
            guard let keep = folders.filter({ depth($0.path) == 1 })
                .max(by: { ($0.fileCount, $1.path) < ($1.fileCount, $0.path) }) else { continue }
            let others = folders.filter { $0.path != keep.path && !$0.path.hasPrefix(keep.path + "/") }.map(\.path).sorted()
            guard !others.isEmpty else { continue }
            merges.append(.init(keep: keep.path, merge: others, reason: "名称含义相同"))
        }
        return ArchiveConsolidationResponse(merges: merges.sorted { $0.keep < $1.keep })
    }

    static func category(forExtension ext: String) -> String? {
        let lower = ext.lowercased()
        return categories.first { $0.extensions.contains(lower) }?.name
    }

    /// Keeps every name; the file kind stands in for a topic. A file lying directly in the workspace moves into
    /// a top-level folder whose name appears in the file's name, or whose name means the file's kind
    /// (a `.mp3` into `music` or `音乐`). Files already in subfolders stay: offline rules cannot judge them.
    static func review(_ request: ArchiveFileReview) -> ArchiveFileDecision {
        let name = request.file.source.lastPathComponent
        let stem = (name as NSString).deletingPathExtension.lowercased()
        let kind = category(forExtension: request.file.source.pathExtension)
        var destination: String?
        var reason = "本机整理不修改文件名。"
        if request.folder.isEmpty {
            let topLevel = request.folders.filter { !$0.contains("/") }
            if let named = topLevel.filter({ $0.count >= 2 && stem.contains($0.lowercased()) }).max(by: { $0.count < $1.count }) {
                destination = named
                reason = "文件名与已有文件夹「\(named)」匹配。"
            } else if let kind,
                      // Audio files fit a music folder too.
                      let match = topLevel.first(where: { folder in
                          ([kind] + (kind == "音频" ? ["音乐"] : [])).contains { equivalenceClass(of: $0).map { $0 == equivalenceClass(of: folder) } ?? false }
                      }) {
                destination = match
                reason = "按文件类型归入已有的「\(match)」。"
            }
        }
        return ArchiveFileDecision(proposedName: name, topic: kind ?? "", folder: destination ?? request.folder,
                                   belongsHere: request.folder.isEmpty ? destination != nil : true, reason: reason)
    }

    /// A folder the user already made whose name appears in the file's name wins; otherwise files of one kind
    /// share a folder once there are at least two of them.
    static func group(_ request: ArchiveGroupingRequest) -> ArchiveGroupingResponse {
        guard request.directory.isEmpty else { return ArchiveGroupingResponse(summary: "本机整理只处理根目录中的文件。", groups: []) }
        var assigned: [String: [String]] = [:]
        var order: [String] = []
        func assign(_ id: String, to folder: String) {
            if assigned[folder] == nil { order.append(folder) }
            assigned[folder, default: []].append(id)
        }
        for file in request.files {
            let stem = (file.name as NSString).deletingPathExtension.lowercased()
            if let named = request.subfolders.filter({ $0.count >= 2 && stem.contains($0.lowercased()) }).max(by: { $0.count < $1.count }) {
                assign(file.id, to: named)
            } else if !file.topic.isEmpty {
                let existing = request.subfolders.first { ArchiveFileSystem.nameKey($0) == ArchiveFileSystem.nameKey(file.topic) }
                assign(file.id, to: existing ?? file.topic)
            }
        }
        let groups = order.map { folder in
            ArchiveGroupingResponse.Group(folder: folder, fileIDs: assigned[folder] ?? [],
                                          reason: request.subfolders.contains(folder) ? "与已有文件夹「\(folder)」匹配。" : "同类文件放在一起。")
        }
        return ArchiveGroupingResponse(summary: "按已有文件夹和文件类型在本机整理，未发送任何数据。", groups: groups)
    }
}
