import Darwin
import Foundation

nonisolated enum ArchiveDirectoryFileSystem {
    static func relativePath(_ url: URL, root: URL) -> String {
        url.path == root.path ? "" : String(url.path.dropFirst(root.path.count + 1))
    }

    static func target(rootID: String, relativePath: String, configuration: ArchiveConfiguration,
                       allowsRoot: Bool = false) throws -> (ArchiveFolder, URL) {
        guard let root = configuration.folders.first(where: { $0.id.uuidString == rootID && $0.role != .excluded }) else {
            throw ArchiveError("AI 引用了未授权的目录。")
        }
        if relativePath.isEmpty && allowsRoot {
            try checkScope(root.url, root: root, configuration: configuration)
            return (root, root.url)
        }
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !relativePath.isEmpty, parts.count <= 6, parts.allSatisfy({ component in
            !component.isEmpty && component != "." && component != ".." && !component.hasPrefix(".") && !component.hasPrefix("~") &&
            component == component.precomposedStringWithCanonicalMapping && component.utf8.count <= 240 &&
            component == component.trimmingCharacters(in: .whitespacesAndNewlines) &&
            !component.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || ":\\".unicodeScalars.contains($0) })
        }) else { throw ArchiveError("AI 目录路径无效：仅接受最多六层的普通相对目录名。") }
        let url = parts.reduce(root.url) { $0.appendingPathComponent($1, isDirectory: true) }
        try checkScope(url, root: root, configuration: configuration)
        return (root, url)
    }

    static func checkScope(_ url: URL, root: ArchiveFolder, configuration: ArchiveConfiguration, deleting: Bool = false) throws {
        guard root.role != .excluded, ArchiveFileSystem.contains(url, in: root.url),
              !configuration.exclusions.contains(where: { ArchiveFileSystem.contains(url, in: $0) }) else {
            throw ArchiveError("目录操作超出授权范围或进入了排除目录。")
        }
        if deleting {
            guard url != root.url,
                  !configuration.folders.contains(where: { ArchiveFileSystem.contains($0.url, in: url) }) else {
                throw ArchiveError("不能删除授权根目录、排除目录或包含这些位置的目录。")
            }
        }
        try ArchiveFileSystem.checkProtectedAncestors(url)
    }

    static func identity(_ url: URL) throws -> ArchiveDirectoryIdentity {
        let fd = try ArchiveFileSystem.openDirectory(url)
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw ArchiveError("无法读取目录身份：\(url.path)") }
        return ArchiveDirectoryIdentity(device: info.st_dev, inode: info.st_ino, permissions: UInt16(info.st_mode & 0o777))
    }

    static func isEmpty(_ url: URL) throws -> Bool {
        _ = try identity(url)
        return try FileManager.default.contentsOfDirectory(atPath: url.path).isEmpty
    }

    static func inventory(_ config: ArchiveConfiguration) throws -> ([ArchiveAIDirectory], [String]) {
        var directories: [ArchiveAIDirectory] = []
        var warnings: [String] = []
        for root in config.folders where root.role != .excluded {
            try checkScope(root.url, root: root, configuration: config)
            directories.append(ArchiveAIDirectory(rootID: root.id.uuidString, relativePath: "",
                                                   identity: try identity(root.url), isEmpty: try isEmpty(root.url)))
            guard let enumerator = FileManager.default.enumerator(at: root.url,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in false }) else {
                throw ArchiveError("无法枚举授权目录。")
            }
            var visited = 0
            for case let url as URL in enumerator {
                try Task.checkCancellation()
                visited += 1
                if visited > 10_000 || directories.count >= 500 {
                    warnings.append("AI 目录树已截取，请缩小授权范围以获得完整规划。")
                    break
                }
                do {
                    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey])
                    if values.isSymbolicLink == true || values.isPackage == true { enumerator.skipDescendants(); continue }
                    guard values.isDirectory == true else { continue }
                    try checkScope(url, root: root, configuration: config)
                    let relative = relativePath(url, root: root.url)
                    if relative.split(separator: "/").count > 6 { enumerator.skipDescendants(); continue }
                    directories.append(ArchiveAIDirectory(rootID: root.id.uuidString, relativePath: relative,
                                                           identity: try identity(url), isEmpty: try isEmpty(url)))
                } catch { enumerator.skipDescendants() }
            }
        }
        return (directories, warnings)
    }

    static func validateCreate(_ target: URL) throws {
        guard !ArchiveFileSystem.exists(target) else { throw ArchiveError("新建目录的目标已存在：\(target.path)") }
        try ArchiveFileSystem.checkCollision(target, ignoring: target)
        _ = try identity(target.deletingLastPathComponent())
    }

    static func create(_ target: URL, permissions: UInt16 = 0o755) throws -> ArchiveDirectoryIdentity {
        try validateCreate(target)
        let parent = try ArchiveFileSystem.openDirectory(target.deletingLastPathComponent())
        defer { close(parent) }
        guard mkdirat(parent, target.lastPathComponent, mode_t(permissions)) == 0 else {
            throw ArchiveError("新建目录失败，目标可能已被占用：\(target.path)")
        }
        _ = fsync(parent)
        return try identity(target)
    }

    static func validateRemoval(_ target: URL, expected: ArchiveDirectoryIdentity) throws {
        guard try identity(target) == expected else { throw ArchiveError("目录身份或权限已变化，请重新规划：\(target.path)") }
        guard try isEmpty(target) else { throw ArchiveError("目录非空，不能删除：\(target.path)") }
    }

    /// AT_REMOVEDIR is deliberately non-recursive and atomically refuses any directory containing an entry.
    static func removeEmpty(_ target: URL, expected: ArchiveDirectoryIdentity) throws {
        try validateRemoval(target, expected: expected)
        let parent = try ArchiveFileSystem.openDirectory(target.deletingLastPathComponent())
        defer { close(parent) }
        let child = openat(parent, target.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else { throw ArchiveError("目录不可访问或已被替换。") }
        defer { close(child) }
        var info = stat(), current = stat()
        guard fstat(child, &info) == 0,
              fstatat(parent, target.lastPathComponent, &current, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_dev == expected.device, info.st_ino == expected.inode,
              current.st_dev == info.st_dev, current.st_ino == info.st_ino,
              current.st_mode & S_IFMT == S_IFDIR else { throw ArchiveError("删除前目录发生变化。") }
        guard unlinkat(parent, target.lastPathComponent, AT_REMOVEDIR) == 0 else {
            throw ArchiveError("目录已非空或不可删除，已保留：\(target.path)")
        }
        _ = fsync(parent)
    }
}
