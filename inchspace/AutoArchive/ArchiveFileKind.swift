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

    /// The convention's category this kind belongs to; its canonical path is where such files live.
    var category: String {
        switch self {
        case .audio: ArchiveCategory.music
        case .video: ArchiveCategory.video
        case .installer: ArchiveCategory.installer
        case .large: ArchiveCategory.large
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
}
