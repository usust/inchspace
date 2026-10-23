import Foundation

/// Files whose type alone says where they go. Songs, videos, installers and very large files carry no text the
/// model could read, and sending them only costs a slow model request per handful of files; they are sorted by
/// type here instead and put into one folder per type.
nonisolated enum ArchiveFileKind: String, CaseIterable, Sendable {
    case audio, video, installer, large

    /// Anything at least this large is sorted by type, whatever its extension: a 10 GB disk image is never read.
    static let largeFileBytes: Int64 = 512 << 20

    private static let extensions: [ArchiveFileKind: Set<String>] = [
        .audio: ["mp3", "flac", "ape", "wav", "aac", "m4a", "aiff", "aif", "ogg", "opus", "wma", "alac", "dsf", "dff", "mid", "midi"],
        .video: ["mp4", "mov", "mkv", "avi", "m4v", "webm", "wmv", "flv", "rmvb", "rm", "ts", "m2ts", "mts", "3gp", "vob", "mpg", "mpeg"],
        .installer: ["dmg", "pkg", "mpkg", "iso", "img", "exe", "msi", "apk", "ipa", "xapk", "deb", "rpm", "appimage", "vmdk", "vdi", "qcow2", "ova"],
    ]

    /// The kind decided by extension first, then by size; nil for files the model should look at.
    static func of(name: String, size: Int64) -> ArchiveFileKind? {
        let ext = (name as NSString).pathExtension.lowercased()
        if let kind = allCases.first(where: { extensions[$0]?.contains(ext) == true }) { return kind }
        return size >= largeFileBytes ? .large : nil
    }

    /// The folder files of this kind are collected in when no existing one fits.
    var folderName: String {
        switch self {
        case .audio: "音乐"
        case .video: "视频"
        case .installer: "安装包与镜像"
        case .large: "大文件"
        }
    }

    var topic: String {
        switch self {
        case .audio: "音乐音频"
        case .video: "视频"
        case .installer: "安装包"
        case .large: "大文件"
        }
    }

    /// Folder names that already mean this kind, compared by `ArchiveFileSystem.nameKey`.
    var aliases: [String] {
        switch self {
        case .audio: ["音乐", "音频", "歌曲", "单曲", "Music", "Audio", "Songs", "iTunes"]
        case .video: ["视频", "影片", "电影", "Videos", "Video", "Movies", "Movie"]
        case .installer: ["安装包与镜像", "安装包", "镜像", "软件", "Installers", "Software", "Apps", "ISO", "Disk Images"]
        case .large: ["大文件", "Large Files"]
        }
    }

    func matches(folderName name: String) -> Bool {
        let key = ArchiveFileSystem.nameKey(name)
        return aliases.contains { ArchiveFileSystem.nameKey($0) == key }
    }
}
