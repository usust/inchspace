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

    private static let workbenchFileName = "inchspace-workbench.json"
    private static let settingsFileName = "inchspace-settings.json"
    private var folderBookmark: Data?
    private var pendingUpload: Task<Void, Never>?
    private var pendingSettingsUpload: Task<Void, Never>?
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
        pendingSettingsUpload?.cancel()
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
                    beginStatusMonitoring(fileName: Self.workbenchFileName)
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
                beginStatusMonitoring(fileName: Self.workbenchFileName)
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
                self.beginStatusMonitoring(fileName: Self.workbenchFileName)
            } catch is CancellationError {
                return
            } catch {
                self.setError(error)
            }
        }
    }

    /// 对少量、可移植的应用偏好执行最后修改时间优先的双向同步。
    func synchronizePreferences(
        localPreferences: SyncedAppPreferences,
        localModifiedAt: Date?,
        allowsUpload: Bool
    ) async -> SyncedPreferencesSnapshot? {
        guard isEnabled, isConfigured else { return nil }
        status = .syncing

        do {
            guard let remote = try readSettingsDocument() else {
                guard allowsUpload else {
                    status = .synced
                    return nil
                }
                let document = SyncedPreferencesSnapshot(
                    preferences: localPreferences,
                    modifiedAt: localModifiedAt ?? Date()
                )
                try writeSettingsDocument(document)
                beginStatusMonitoring(fileName: Self.settingsFileName)
                return document
            }

            guard let localModifiedAt else {
                markSuccessfulSync()
                return remote
            }

            if remote.modifiedAt > localModifiedAt {
                markSuccessfulSync()
                return remote
            }

            if allowsUpload, localModifiedAt > remote.modifiedAt {
                let document = SyncedPreferencesSnapshot(
                    preferences: localPreferences,
                    modifiedAt: localModifiedAt
                )
                try writeSettingsDocument(document)
                beginStatusMonitoring(fileName: Self.settingsFileName)
            } else {
                await updateTransferStatus(for: try syncFileURL(fileName: Self.settingsFileName))
            }
            return nil
        } catch {
            setError(error)
            return nil
        }
    }

    func schedulePreferencesUpload(
        _ preferences: SyncedAppPreferences,
        modifiedAt: Date
    ) {
        guard isEnabled, isConfigured else { return }
        pendingSettingsUpload?.cancel()
        pendingSettingsUpload = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, let self else { return }
            self.status = .syncing
            do {
                if let remote = try self.readSettingsDocument(),
                   remote.modifiedAt >= modifiedAt {
                    self.markSuccessfulSync()
                    return
                }
                let document = SyncedPreferencesSnapshot(
                    preferences: preferences,
                    modifiedAt: modifiedAt
                )
                try self.writeSettingsDocument(document)
                self.beginStatusMonitoring(fileName: Self.settingsFileName)
            } catch is CancellationError {
                return
            } catch {
                self.setError(error)
            }
        }
    }

    private func syncFileURL() throws -> URL {
        try syncFileURL(fileName: Self.workbenchFileName)
    }

    private func syncFileURL(fileName: String) throws -> URL {
        guard let bookmark = folderBookmark else { throw SyncError.notConfigured }
        return try SecurityScopedBookmarkService.resolve(bookmark)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    private func readSnapshot() throws -> FileSnapshot? {
        guard let bookmark = folderBookmark else { throw SyncError.notConfigured }
        return try SecurityScopedBookmarkService.withAccess(
            to: bookmark,
            fallbackURL: URL(fileURLWithPath: "/")
        ) { folderURL in
            let fileURL = folderURL.appendingPathComponent(Self.workbenchFileName)
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
        let data = try LaunchpadJSONCodec.encode(library.cloudPortableCopy())
        try SecurityScopedBookmarkService.withAccess(
            to: bookmark,
            fallbackURL: URL(fileURLWithPath: "/")
        ) { folderURL in
            let fileURL = folderURL.appendingPathComponent(Self.workbenchFileName)
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

    private func readSettingsDocument() throws -> SyncedPreferencesSnapshot? {
        guard let bookmark = folderBookmark else { throw SyncError.notConfigured }
        return try SecurityScopedBookmarkService.withAccess(
            to: bookmark,
            fallbackURL: URL(fileURLWithPath: "/")
        ) { folderURL in
            let fileURL = folderURL.appendingPathComponent(Self.settingsFileName)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }

            var coordinationError: NSError?
            var result: SyncedPreferencesSnapshot?
            var readError: Error?
            NSFileCoordinator().coordinate(readingItemAt: fileURL, options: [], error: &coordinationError) { url in
                do {
                    var candidates = [(url, Self.modificationDate(of: url))]
                    for version in NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? [] {
                        candidates.append((version.url, version.modificationDate ?? .distantPast))
                    }
                    for (candidateURL, _) in candidates.sorted(by: { $0.1 > $1.1 }) {
                        guard let data = try? Data(contentsOf: candidateURL),
                              let document = try? LaunchpadJSONCodec.decode(
                                SyncedPreferencesSnapshot.self,
                                from: data
                              ) else { continue }
                        if result == nil || document.modifiedAt > result!.modifiedAt {
                            result = document
                        }
                    }
                    guard result != nil else { throw SyncError.invalidSettingsData }
                } catch {
                    readError = error
                }
            }
            if let coordinationError { throw coordinationError }
            if let readError { throw readError }
            return result
        }
    }

    private func writeSettingsDocument(_ document: SyncedPreferencesSnapshot) throws {
        guard let bookmark = folderBookmark else { throw SyncError.notConfigured }
        let data = try LaunchpadJSONCodec.encode(document)
        try SecurityScopedBookmarkService.withAccess(
            to: bookmark,
            fallbackURL: URL(fileURLWithPath: "/")
        ) { folderURL in
            let fileURL = folderURL.appendingPathComponent(Self.settingsFileName)
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

    private func beginStatusMonitoring(fileName: String) {
        statusMonitor?.cancel()
        statusMonitor = Task { [weak self] in
            guard let self, let fileURL = try? self.syncFileURL(fileName: fileName) else { return }
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
        pendingSettingsUpload?.cancel()
        statusMonitor?.cancel()
        pendingUpload = nil
        pendingSettingsUpload = nil
        statusMonitor = nil
    }

    private struct FileSnapshot {
        let library: LaunchpadLibrary
        let modifiedAt: Date
    }

    struct SyncedPreferencesSnapshot: Codable, Equatable {
        var schemaVersion = 1
        let preferences: SyncedAppPreferences
        let modifiedAt: Date

        private enum CodingKeys: String, CodingKey {
            case schemaVersion
            case preferences
            case modifiedAt
        }

        init(preferences: SyncedAppPreferences, modifiedAt: Date) {
            self.preferences = preferences
            self.modifiedAt = modifiedAt
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
            preferences = try container.decode(SyncedAppPreferences.self, forKey: .preferences)
            if let timestamp = try? container.decode(Double.self, forKey: .modifiedAt) {
                modifiedAt = Date(timeIntervalSince1970: timestamp)
            } else {
                // 兼容曾使用 JSONEncoder.iso8601 写出的预发布设置文件。
                modifiedAt = try container.decode(Date.self, forKey: .modifiedAt)
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(schemaVersion, forKey: .schemaVersion)
            try container.encode(preferences, forKey: .preferences)
            // ISO-8601 编码会丢失亚秒精度，可能让快速连续修改发生错误覆盖。
            try container.encode(modifiedAt.timeIntervalSince1970, forKey: .modifiedAt)
        }
    }

    private enum SyncError: LocalizedError {
        case notConfigured
        case notDirectory
        case notICloudDrive
        case invalidCloudData
        case invalidSettingsData
        case folderAccessFailed(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: "尚未选择 iCloud Drive 同步文件夹。"
            case .notDirectory: "请选择一个文件夹。"
            case .notICloudDrive: "请选择 iCloud Drive 中的文件夹。"
            case .invalidCloudData: "iCloud Drive 中的工作台数据无法读取。"
            case .invalidSettingsData: "iCloud Drive 中的设置数据无法读取。"
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
