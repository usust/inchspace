import CryptoKit
import Darwin
import Foundation

/// All mutations use directory descriptors and the macOS exclusive-rename primitive.
nonisolated enum ArchiveFileSystem {
    static func contains(_ child: URL, in root: URL) -> Bool {
        guard !child.pathComponents.contains(".."), !root.pathComponents.contains("..") else { return false }
        let path = child.path
        let base = root.path
        return path == base || path.hasPrefix(base == "/" ? "/" : base + "/")
    }

    static func openDirectory(_ url: URL) throws -> Int32 {
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw posixError("打开目录失败") }
        do {
            for component in url.pathComponents.dropFirst() {
                let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw posixError("目录不可访问或包含符号链接：\(url.path)") }
                close(fd)
                fd = next
            }
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    static func validateConfiguration(_ config: ArchiveConfiguration, stateDirectory: URL, requiresDirectoryAccess: Bool = true) throws {
        guard !config.inboxes.isEmpty, !config.libraries.isEmpty else {
            throw ArchiveError("请至少添加一个待整理目录和一个归档资料库。")
        }
        guard config.stableSeconds >= 0, (1...1000).contains(config.sampleLimit),
              (1...20_000_000).contains(config.maxFileBytes) else { throw ArchiveError("扫描限制无效。") }
        for folder in config.folders where folder.role != .excluded {
            if requiresDirectoryAccess {
                let fd = try openDirectory(folder.url)
                close(fd)
                try checkProtectedAncestors(folder.url)
            }
            guard !contains(stateDirectory, in: folder.url) else {
                throw ArchiveError("目录范围包含应用归档记录，请选择更具体的文件夹。")
            }
        }
        // Every authorized root must stand alone: no duplicates and no nesting between any two of them.
        let roots = config.folders.filter { $0.role != .excluded }.map(\.url)
        for (index, root) in roots.enumerated() {
            guard !roots.dropFirst(index + 1).contains(where: { contains(root, in: $0) || contains($0, in: root) }) else {
                throw ArchiveError("目录不能重复或互相包含。")
            }
        }
    }

    static func check(_ url: URL, role: ArchiveFolderRole, config: ArchiveConfiguration) throws {
        let roots = role == .inbox ? config.inboxes : config.libraries
        guard roots.contains(where: { contains(url, in: $0) }),
              !config.exclusions.contains(where: { contains(url, in: $0) }) else {
            throw ArchiveError("路径已超出配置范围或被排除：\(url.path)")
        }
        let parent = try openDirectory(url.deletingLastPathComponent())
        defer { close(parent) }
        var info = stat()
        if fstatat(parent, url.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0,
           info.st_mode & S_IFMT == S_IFLNK { throw ArchiveError("不处理符号链接：\(url.path)") }
        try checkProtectedAncestors(url)
    }

    static func checkProtectedAncestors(_ url: URL) throws {
        var current = url
        while current.path != "/" {
            let name = current.lastPathComponent.lowercased()
            if name.hasPrefix(".") || ["app", "bundle", "photoslibrary", "photolibrary", "framework"].contains(current.pathExtension.lowercased()) {
                throw ArchiveError("跳过隐藏位置或应用资料包：\(current.path)")
            }
            if [".git", ".hg", ".svn"].contains(where: { exists(current.appendingPathComponent($0)) }) {
                throw ArchiveError("跳过代码仓库：\(current.path)")
            }
            current.deleteLastPathComponent()
        }
    }

    static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    static func read(_ url: URL, maxBytes: Int) throws -> (ArchiveFingerprint, Data) {
        let parent = try openDirectory(url.deletingLastPathComponent())
        defer { close(parent) }
        let fd = openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw posixError("读取文件失败：\(url.lastPathComponent)") }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_nlink == 1, before.st_size <= maxBytes else {
            throw ArchiveError("只处理大小不超过 \(maxBytes / 1_000_000) MB 的普通单链接文件。")
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 131_072)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw posixError("读取文件失败")
            }
            guard data.count + count <= maxBytes else { throw ArchiveError("读取过程中，文件超过大小限制。") }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat(), current = stat()
        guard fstat(fd, &after) == 0,
              fstatat(parent, url.lastPathComponent, &current, AT_SYMLINK_NOFOLLOW) == 0,
              sameStat(before, after), sameStat(after, current) else {
            throw ArchiveError("文件在读取时发生变化，请重新扫描。")
        }
        return (ArchiveFingerprint(device: after.st_dev, inode: after.st_ino, size: after.st_size,
                                   modifiedSeconds: Int64(after.st_mtimespec.tv_sec),
                                   modifiedNanoseconds: Int64(after.st_mtimespec.tv_nsec),
                                   sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()), data)
    }

    /// Identity plus a content hash. The file is streamed, so size does not matter and nothing large is held in memory.
    /// `maxBytes` only bounds reads that keep the content (`read`); hashing has no size limit. Files above
    /// `sampledHashThreshold` hash only their first and last `sampledHashChunk` bytes plus the size, so a
    /// large video is identified in milliseconds instead of being read end to end.
    static let sampledHashThreshold: Int64 = 64 << 20
    static let sampledHashChunk = 4 << 20

    static func fingerprint(_ url: URL, maxBytes: Int = .max) throws -> ArchiveFingerprint {
        let parent = try openDirectory(url.deletingLastPathComponent())
        defer { close(parent) }
        let fd = openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw posixError("读取文件失败：\(url.lastPathComponent)") }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1 else {
            throw ArchiveError("只处理普通的单链接文件。")
        }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        func hash(upTo limit: Int) throws {
            var remaining = limit
            while remaining > 0 {
                try Task.checkCancellation()
                let count = Darwin.read(fd, &buffer, min(buffer.count, remaining))
                if count == 0 { break }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw posixError("读取文件失败")
                }
                remaining -= count
                buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0.prefix(count))) }
            }
        }
        if before.st_size > sampledHashThreshold {
            try hash(upTo: sampledHashChunk)
            guard lseek(fd, before.st_size - Int64(sampledHashChunk), SEEK_SET) >= 0 else { throw posixError("读取文件失败") }
            try hash(upTo: sampledHashChunk)
            var size = before.st_size
            withUnsafeBytes(of: &size) { hasher.update(bufferPointer: $0) }
        } else {
            try hash(upTo: .max)
        }
        var after = stat(), current = stat()
        guard fstat(fd, &after) == 0,
              fstatat(parent, url.lastPathComponent, &current, AT_SYMLINK_NOFOLLOW) == 0,
              sameStat(before, after), sameStat(after, current) else {
            throw ArchiveError("文件在读取时发生变化，请重新扫描。")
        }
        return ArchiveFingerprint(device: after.st_dev, inode: after.st_ino, size: after.st_size,
                                  modifiedSeconds: Int64(after.st_mtimespec.tv_sec),
                                  modifiedNanoseconds: Int64(after.st_mtimespec.tv_nsec),
                                  sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }

    /// Identity, size and modification time without reading the file. Enough to tell that a file is unchanged;
    /// `sha256` is left empty and filled in only for files that are actually processed.
    static func quickFingerprint(_ url: URL) throws -> ArchiveFingerprint {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw ArchiveError("不是普通文件：\(url.lastPathComponent)") }
        return ArchiveFingerprint(device: info.st_dev, inode: info.st_ino, size: info.st_size,
                                  modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
                                  modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec), sha256: "")
    }

    /// Files up to this size are re-hashed whenever a move checks them; larger ones are checked by identity,
    /// size and modification time, which is what the skip logic trusts anyway.
    static let fullVerifyLimit: Int64 = 8 << 20

    /// True when the file at `url` is still the one `expected` describes.
    static func matches(_ url: URL, _ expected: ArchiveFingerprint, maxBytes: Int = .max) -> Bool {
        guard let quick = try? quickFingerprint(url), quick.sameMetadata(expected) else { return false }
        guard quick.size <= fullVerifyLimit, !expected.sha256.isEmpty else { return true }
        return (try? fingerprint(url, maxBytes: maxBytes)) == expected
    }

    /// The file's birth time, when the volume records one.
    static func creationSeconds(_ url: URL) -> Int64? {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_birthtimespec.tv_sec > 0 else { return nil }
        return Int64(info.st_birthtimespec.tv_sec)
    }

    private static func sameStat(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size &&
        a.st_nlink == b.st_nlink && a.st_mode == b.st_mode &&
        a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }

    /// Lists the regular files under the roots. With `hashing: false` only metadata is read, which keeps a
    /// rescan of a large, mostly unchanged folder fast.
    static func scan(_ config: ArchiveConfiguration, role: ArchiveFolderRole, hashing: Bool = true) throws -> ArchiveScanResult {
        var result = ArchiveScanResult()
        let roots = role == .inbox ? config.inboxes : config.libraries
        var visited = 0
        for root in roots {
            try check(root, role: role, config: config)
            var enumerationWarnings: [String] = []
            guard let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { url, _ in
                    if enumerationWarnings.count < 20 { enumerationWarnings.append("无法读取：\(url.path)") }
                    return true
                }
            ) else { throw ArchiveError("无法扫描目录：\(root.path)") }
            for case let url as URL in enumerator {
                try Task.checkCancellation()
                visited += 1
                if visited > 10_000 {
                    result.warnings.append("单次扫描上限为 10,000 个目录项；请缩小范围或添加排除目录。")
                    result.warnings += enumerationWarnings
                    return result
                }
                do {
                    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey])
                    try check(url, role: role, config: config)
                    if values.isSymbolicLink == true || values.isPackage == true {
                        enumerator.skipDescendants()
                        continue
                    }
                    if values.isDirectory == true { continue }
                    guard values.isRegularFile == true,
                          !["part", "crdownload", "download", "tmp", "swp"].contains(url.pathExtension.lowercased()) else { continue }
                    let fp = hashing ? try fingerprint(url) : try quickFingerprint(url)
                    result.files.append(ArchiveEvidence(url: url, fingerprint: fp, words: [], extractionNote: nil))
                } catch {
                    enumerator.skipDescendants()
                    if result.warnings.count < 20 { result.warnings.append("跳过 \(url.lastPathComponent)：\(error.localizedDescription)") }
                }
            }
            result.warnings += enumerationWarnings
        }
        result.files.sort { $0.url.path < $1.url.path }
        return result
    }

    static func nameKey(_ name: String) -> String {
        name.decomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    static func normalizedName(_ input: String) throws -> String {
        let replaced = input.precomposedStringWithCanonicalMapping.unicodeScalars.map { scalar -> String in
            scalar.value < 0x20 || scalar.value == 0x7f || "/:\\".unicodeScalars.contains(scalar) ? "_" : String(scalar)
        }.joined()
        let trimmed = replaced.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        let ext = (trimmed as NSString).pathExtension
        let suffix = ext.isEmpty ? "" : "." + ext
        guard suffix.utf8.count <= 40 else { throw ArchiveError("文件扩展名过长，无法安全规范命名。") }
        var stem = suffix.isEmpty ? trimmed : String(trimmed.dropLast(suffix.count))
        func cleanStem(_ input: String) -> String {
            var value = input.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
            if !suffix.isEmpty {
                while value.lowercased().hasSuffix(suffix.lowercased()) {
                    value = String(value.dropLast(suffix.count)).trimmingCharacters(in: CharacterSet(charactersIn: " ."))
                }
            }
            return value.isEmpty ? "untitled" : value
        }
        stem = cleanStem(stem.split(whereSeparator: \.isWhitespace).joined(separator: " "))
        while (stem + suffix).utf8.count > 240 { stem.removeLast() }
        // Truncation may expose trailing dots, whitespace or another copy of the extension.
        return cleanStem(stem) + suffix
    }

    static func checkCollision(_ target: URL, ignoring source: URL) throws {
        let entries = try FileManager.default.contentsOfDirectory(at: target.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        if entries.contains(where: { $0.path != source.path && nameKey($0.lastPathComponent) == nameKey(target.lastPathComponent) }) {
            throw ArchiveError("目标已存在同名、大小写或 Unicode 等价的文件：\(target.lastPathComponent)")
        }
    }

    static func validateMove(source: URL, target: URL, expected: ArchiveFingerprint, maxBytes: Int) throws {
        guard source != target else { throw ArchiveError("文件名和位置均无变化，无需执行。") }
        guard matches(source, expected, maxBytes: maxBytes) else { throw ArchiveError("源文件已变化，请重新生成建议。") }
        try checkCollision(target, ignoring: source)
        let fd = try openDirectory(target.deletingLastPathComponent())
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_dev == expected.device else { throw ArchiveError("暂不支持跨磁盘归档，请选择同一卷上的目录。") }
    }

    static func move(source: URL, target: URL, staging: URL, expected: ArchiveFingerprint, maxBytes: Int) throws {
        try validateMove(source: source, target: target, expected: expected, maxBytes: maxBytes)
        guard staging.deletingLastPathComponent() == source.deletingLastPathComponent(), !exists(staging) else {
            throw ArchiveError("暂存位置不可用，请检查操作记录。")
        }
        let sfd = try openDirectory(source.deletingLastPathComponent())
        defer { close(sfd) }
        let tfd = try openDirectory(target.deletingLastPathComponent())
        defer { close(tfd) }
        try renameExclusive(sfd, source.lastPathComponent, sfd, staging.lastPathComponent)
        _ = fsync(sfd)
        // If a replacement was captured, preserve it at the recorded staging path for review.
        guard matches(staging, expected, maxBytes: maxBytes) else {
            throw ArchiveError("移动前源文件被替换，已保留暂存文件：\(staging.path)")
        }
        do {
            try checkCollision(target, ignoring: staging)
            // Reopening validates that the paths still refer to the held directories.
            try verifyDirectory(source.deletingLastPathComponent(), descriptor: sfd)
            try verifyDirectory(target.deletingLastPathComponent(), descriptor: tfd)
            try renameExclusive(sfd, staging.lastPathComponent, tfd, target.lastPathComponent)
        } catch {
            try? renameExclusive(sfd, staging.lastPathComponent, sfd, source.lastPathComponent)
            _ = fsync(sfd)
            throw error
        }
        _ = fsync(sfd)
        _ = fsync(tfd)
        guard matches(target, expected, maxBytes: maxBytes) else {
            throw ArchiveError("提交后检测到文件变化，请检查操作记录。")
        }
    }

    private static func verifyDirectory(_ url: URL, descriptor: Int32) throws {
        let current = try openDirectory(url)
        defer { close(current) }
        var a = stat(), b = stat()
        guard fstat(current, &a) == 0, fstat(descriptor, &b) == 0,
              a.st_dev == b.st_dev, a.st_ino == b.st_ino else { throw ArchiveError("目录在操作期间发生变化。") }
    }

    private static func renameExclusive(_ sourceFD: Int32, _ sourceName: String, _ targetFD: Int32, _ targetName: String) throws {
        guard renameatx_np(sourceFD, sourceName, targetFD, targetName, UInt32(RENAME_EXCL)) == 0 else {
            throw posixError("无法移动文件（目标可能已被占用）")
        }
    }

    private static func posixError(_ prefix: String) -> ArchiveError {
        ArchiveError("\(prefix)：\(String(cString: strerror(errno)))")
    }
}
