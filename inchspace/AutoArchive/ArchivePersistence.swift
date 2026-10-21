import Darwin
import Foundation

/// One writer per state directory, with a durable private journal before every file move.
nonisolated final class ArchivePersistence: @unchecked Sendable {
    let directory: URL
    private let directoryFD: Int32
    private let lockFD: Int32

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("inchspace/AutoArchive", isDirectory: true)
            .resolvingSymlinksInPath()
    }

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let fd = try ArchiveFileSystem.openDirectory(self.directory)
        let lock = openat(fd, "archive.lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else {
            close(fd)
            throw ArchiveError("无法打开归档记录锁。")
        }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            close(lock)
            close(fd)
            throw ArchiveError("另一应用实例正在使用自动归档，请先关闭该实例。")
        }
        directoryFD = fd
        lockFD = lock
        _ = fchmod(fd, 0o700)
        _ = fchmod(lock, 0o600)
    }

    deinit {
        _ = flock(lockFD, LOCK_UN)
        close(lockFD)
        close(directoryFD)
    }

    func load() throws -> ArchiveState {
        let fd = openat(directoryFD, "archive.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return ArchiveState() }
            throw ArchiveError("无法读取归档记录；现有记录不会被重置。")
        }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size < 100_000_000 else {
            close(fd)
            throw ArchiveError("归档记录不是有效文件或过大，需手动检查。")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let data = try handle.readToEnd() ?? Data()
        do { return try JSONDecoder().decode(ArchiveState.self, from: data) }
        catch { throw ArchiveError("归档记录无法解析，请检查 \(directory.appendingPathComponent("archive.json").path)。原文件已保留。") }
    }

    func save(_ state: ArchiveState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        guard data.count < 100_000_000 else {
            throw ArchiveError("归档记录超过 100 MB，无法保存。现有记录已保留，文件操作已停止。")
        }
        let temporary = ".archive-\(UUID().uuidString)"
        let fd = openat(directoryFD, temporary, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ArchiveError("无法写入归档记录。") }
        defer {
            close(fd)
            _ = unlinkat(directoryFD, temporary, 0)
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ArchiveError("写入归档记录失败，已停止操作。") }
                offset += count
            }
        }
        guard fsync(fd) == 0, renameat(directoryFD, temporary, directoryFD, "archive.json") == 0 else {
            throw ArchiveError("无法提交归档记录，已停止操作。")
        }
        _ = fsync(directoryFD)
    }
}
