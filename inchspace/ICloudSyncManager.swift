//
//  ICloudSyncManager.swift
//  inchspace
//
//  将工作台快照保存到用户主动选择的 iCloud Drive 文件夹。
//

import AppKit
import Combine
import Foundation

enum ICloudSyncStatus: Equatable {
    case notConfigured
    case disabled
    case unavailable
    case syncing
    case synced
    case error(String)
}

@MainActor
final class ICloudSyncManager: ObservableObject {
    @Published private(set) var status: ICloudSyncStatus
    @Published private(set) var lastSuccessfulSync: Date?
    @Published private(set) var isEnabled: Bool
    @Published private(set) var selectedFolderName: String?

    private enum Key {
        static let enabled = "iCloudDriveSyncEnabled"
        static let bookmark = "iCloudDriveSyncFolderBookmark"
        static let lastSuccessfulSync = "iCloudDriveLastSuccessfulSync"
    }

    private static let fileName = "inchspace-workbench.json"
    private var folderBookmark: Data?
    private var pendingUpload: Task<Void, Never>?
    private var statusMonitor: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        let storedEnabled = defaults.object(forKey: Key.enabled) as? Bool ?? true
        isEnabled = storedEnabled
        lastSuccessfulSync = defaults.object(forKey: Key.lastSuccessfulSync) as? Date
        folderBookmark = defaults.data(forKey: Key.bookmark)

        if let bookmark = folderBookmark,
           let url = try? SecurityScopedBookmarkService.resolve(bookmark) {
            selectedFolderName = url.lastPathComponent
            status = storedEnabled ? .syncing : .disabled
        } else {
            folderBookmark = nil
            selectedFolderName = nil
            status = .notConfigured
        }
    }

    deinit {
        pendingUpload?.cancel()
        statusMonitor?.cancel()
    }

    var isConfigured: Bool { folderBookmark != nil }

    func configureFolder(_ url: URL) throws {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing { url.stopAccessingSecurityScopedResource() }
        }

        let bookmark: Data
        do {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isUbiquitousItemKey])
            guard values.isDirectory == true else { throw SyncError.notDirectory }
            guard values.isUbiquitousItem == true else { throw SyncError.notICloudDrive }
            bookmark = try SecurityScopedBookmarkService.makeWritableBookmark(for: url)
        } catch let error as SyncError {
            throw error
        } catch {
            throw SyncError.folderAccessFailed(error.localizedDescription)
        }

        cancelPendingWork()
        folderBookmark = bookmark
        selectedFolderName = url.lastPathComponent
        isEnabled = true
        let defaults = UserDefaults.standard
        defaults.set(bookmark, forKey: Key.bookmark)
        defaults.set(true, forKey: Key.enabled)
        status = .syncing
    }

    func removeFolder() {
        cancelPendingWork()
        folderBookmark = nil
        selectedFolderName = nil
        UserDefaults.standard.removeObject(forKey: Key.bookmark)
        status = .notConfigured
    }

    func revealFolderInFinder() throws {
        guard let bookmark = folderBookmark else { throw SyncError.notConfigured }
        try SecurityScopedBookmarkService.withAccess(
            to: bookmark,
            fallbackURL: URL(fileURLWithPath: "/")
        ) { folderURL in
            NSWorkspace.shared.activateFileViewerSelecting([folderURL])
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Key.enabled)
        cancelPendingWork()
        status = enabled ? (isConfigured ? .syncing : .notConfigured) : .disabled
    }

    func refreshAccountStatus() async {
        guard isEnabled else {
            status = .disabled
            return
        }
        guard let fileURL = try? syncFileURL() else {
            status = isConfigured ? .unavailable : .notConfigured
            return
        }
        await updateTransferStatus(for: fileURL)
    }

    /// 云端文件较新则返回其内容；本地较新时可选择上传。
    func synchronize(
        localLibrary: LaunchpadLibrary,
        localModifiedAt: Date?,
        allowsUpload: Bool
    ) async -> LaunchpadLibrary? {
        guard isEnabled, isConfigured else {
            status = isEnabled ? .notConfigured : .disabled
            return nil
        }
        status = .syncing

        do {
            guard let snapshot = try readSnapshot() else {
                if allowsUpload {
                    try write(localLibrary)
                    beginStatusMonitoring()
                } else {
                    status = .synced
                }
                return nil
            }

            guard let localModifiedAt else {
                markSuccessfulSync()
                return snapshot.library
            }

            if snapshot.modifiedAt > localModifiedAt {
                markSuccessfulSync()
                return snapshot.library
            }

            if allowsUpload, localModifiedAt > snapshot.modifiedAt {
                try write(localLibrary)
                beginStatusMonitoring()
            } else {
                await updateTransferStatus(for: try syncFileURL())
            }
            return nil
        } catch {
            setError(error)
            return nil
        }
    }

    func scheduleUpload(_ library: LaunchpadLibrary) {
        guard isEnabled, isConfigured else { return }
        pendingUpload?.cancel()
        pendingUpload = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, let self else { return }
            self.status = .syncing
            do {
                try self.write(library)
                self.beginStatusMonitoring()
            } catch is CancellationError {
                return
            } catch {
                self.setError(error)
            }
        }
    }

    private func syncFileURL() throws -> URL {
        guard let bookmark = folderBookmark else { throw SyncError.notConfigured }
        return try SecurityScopedBookmarkService.resolve(bookmark)
            .appendingPathComponent(Self.fileName, isDirectory: false)
    }

    private func readSnapshot() throws -> FileSnapshot? {
        guard let bookmark = folderBookmark else { throw SyncError.notConfigured }
        return try SecurityScopedBookmarkService.withAccess(
            to: bookmark,
            fallbackURL: URL(fileURLWithPath: "/")
        ) { folderURL in
            let fileURL = folderURL.appendingPathComponent(Self.fileName)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }

            var coordinationError: NSError?
            var result: FileSnapshot?
            var readError: Error?
            NSFileCoordinator().coordinate(readingItemAt: fileURL, options: [], error: &coordinationError) { url in
                do {
                    var candidates = [(url, Self.modificationDate(of: url))]
                    for version in NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? [] {
                        candidates.append((version.url, version.modificationDate ?? .distantPast))
                    }
                    for (candidateURL, date) in candidates.sorted(by: { $0.1 > $1.1 }) {
                        guard let data = try? Data(contentsOf: candidateURL),
                              let library = try? LaunchpadJSONCodec.decode(LaunchpadLibrary.self, from: data) else {
                            continue
                        }
                        result = FileSnapshot(library: library, modifiedAt: date)
                        break
                    }
                    guard result != nil else { throw SyncError.invalidCloudData }
                } catch {
                    readError = error
                }
            }
            if let coordinationError { throw coordinationError }
            if let readError { throw readError }
            return result
        }
    }

    private func write(_ library: LaunchpadLibrary) throws {
        guard let bookmark = folderBookmark else { throw SyncError.notConfigured }
        let data = try LaunchpadJSONCodec.encode(library)
        try SecurityScopedBookmarkService.withAccess(
            to: bookmark,
            fallbackURL: URL(fileURLWithPath: "/")
        ) { folderURL in
            let fileURL = folderURL.appendingPathComponent(Self.fileName)
            var coordinationError: NSError?
            var writeError: Error?
            NSFileCoordinator().coordinate(
                writingItemAt: fileURL,
                options: .forReplacing,
                error: &coordinationError
            ) { url in
                do {
                    try data.write(to: url, options: .atomic)
                } catch {
                    writeError = error
                }
            }
            if let coordinationError { throw coordinationError }
            if let writeError { throw writeError }
        }
    }

    private func beginStatusMonitoring() {
        statusMonitor?.cancel()
        statusMonitor = Task { [weak self] in
            guard let self, let fileURL = try? self.syncFileURL() else { return }
            for _ in 0..<12 {
                guard !Task.isCancelled else { return }
                await self.updateTransferStatus(for: fileURL)
                if self.status == .synced || self.status.isFailure { return }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func updateTransferStatus(for fileURL: URL) async {
        guard let bookmark = folderBookmark else {
            status = .notConfigured
            return
        }
        do {
            let values = try SecurityScopedBookmarkService.withAccess(
                to: bookmark,
                fallbackURL: fileURL.deletingLastPathComponent()
            ) { _ in
                try fileURL.resourceValues(forKeys: [
                    .ubiquitousItemIsUploadedKey,
                    .ubiquitousItemIsUploadingKey,
                    .ubiquitousItemUploadingErrorKey,
                ])
            }
            if let error = values.ubiquitousItemUploadingError { throw error }
            if values.ubiquitousItemIsUploaded == true && values.ubiquitousItemIsUploading != true {
                markSuccessfulSync()
            } else {
                status = .syncing
            }
        } catch {
            setError(error)
        }
    }

    private func markSuccessfulSync() {
        let now = Date()
        lastSuccessfulSync = now
        UserDefaults.standard.set(now, forKey: Key.lastSuccessfulSync)
        status = .synced
    }

    private func setError(_ error: Error) {
        status = .error(error.localizedDescription)
    }

    private func cancelPendingWork() {
        pendingUpload?.cancel()
        statusMonitor?.cancel()
        pendingUpload = nil
        statusMonitor = nil
    }

    private struct FileSnapshot {
        let library: LaunchpadLibrary
        let modifiedAt: Date
    }

    private enum SyncError: LocalizedError {
        case notConfigured
        case notDirectory
        case notICloudDrive
        case invalidCloudData
        case folderAccessFailed(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: "尚未选择 iCloud Drive 同步文件夹。"
            case .notDirectory: "请选择一个文件夹。"
            case .notICloudDrive: "请选择 iCloud Drive 中的文件夹。"
            case .invalidCloudData: "iCloud Drive 中的工作台数据无法读取。"
            case let .folderAccessFailed(message): "无法访问所选文件夹：\(message)"
            }
        }
    }

    private static func modificationDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }

}

private extension ICloudSyncStatus {
    var isFailure: Bool {
        switch self {
        case .unavailable, .error: true
        default: false
        }
    }
}
