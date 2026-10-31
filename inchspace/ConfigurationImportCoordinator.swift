import Foundation

@MainActor
struct ConfigurationImportCoordinator {
    struct Result {
        let recoveryURL: URL
        let itemCount: Int
        let needsAuthorizationCount: Int
    }

    let recoveryDirectory: URL
    private let writeRecovery: @MainActor (ConfigurationBackup, URL) throws -> Void
    private let applyPreferences: @MainActor (AppWindowPreferences, PortableAppPreferences) throws -> Void

    init(
        recoveryDirectory: URL? = nil,
        writeRecovery: @escaping @MainActor (ConfigurationBackup, URL) throws -> Void = { try $0.write(to: $1) },
        applyPreferences: @escaping @MainActor (AppWindowPreferences, PortableAppPreferences) throws -> Void = {
            $0.applyPortablePreferences($1)
        }
    ) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.recoveryDirectory = recoveryDirectory ?? base
            .appendingPathComponent("vip.lylab.inchspace", isDirectory: true)
            .appendingPathComponent("ConfigurationBackups", isDirectory: true)
        self.writeRecovery = writeRecovery
        self.applyPreferences = applyPreferences
    }

    func snapshot(repository: LaunchpadRepository, preferences: AppWindowPreferences) throws -> ConfigurationBackup {
        ConfigurationBackup(
            library: try repository.configurationSnapshot(),
            preferences: preferences.portablePreferences,
            appVersion: AppVersion.shortVersion
        )
    }

    func importConfiguration(
        _ document: ConfigurationBackup,
        repository: LaunchpadRepository,
        preferences: AppWindowPreferences
    ) throws -> Result {
        // Validate even documents constructed in memory, before touching current state.
        _ = try document.encoded()
        let originalLibrary = try repository.configurationSnapshot()
        let originalPreferences = preferences.portablePreferences
        let recovery = ConfigurationBackup(
            library: originalLibrary,
            preferences: originalPreferences,
            appVersion: AppVersion.shortVersion
        )
        let recoveryURL = recoveryDirectory.appendingPathComponent(
            "before-import-\(UUID().uuidString).\(ConfigurationBackup.fileExtension)"
        )
        do {
            try FileManager.default.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
            try writeRecovery(recovery, recoveryURL)
        } catch {
            throw ConfigurationImportError.backupFailed(error.localizedDescription)
        }

        let replacement = Self.preparedLibrary(document.library, local: originalLibrary)
        do {
            try repository.replaceConfiguration(replacement)
        } catch {
            throw ConfigurationImportError.importFailed(error.localizedDescription, recoveryURL)
        }
        do {
            try applyPreferences(preferences, document.preferences)
        } catch {
            let importError = error.localizedDescription
            var rollbackErrors: [String] = []
            do { try repository.replaceConfiguration(originalLibrary) }
            catch { rollbackErrors.append(error.localizedDescription) }
            do { try applyPreferences(preferences, originalPreferences) }
            catch { rollbackErrors.append(error.localizedDescription) }
            if !rollbackErrors.isEmpty {
                throw ConfigurationImportError.rollbackFailed(importError, rollbackErrors.joined(separator: "；"), recoveryURL)
            }
            throw ConfigurationImportError.importFailed(importError, recoveryURL)
        }
        return Result(
            recoveryURL: recoveryURL,
            itemCount: replacement.items.count,
            needsAuthorizationCount: replacement.items.filter { !$0.isAvailable }.count
        )
    }

    static func preparedLibrary(_ imported: LaunchpadLibrary, local: LaunchpadLibrary) -> LaunchpadLibrary {
        var result = imported.restoringDeviceState(from: local)
        let localByID = Dictionary(local.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for index in result.items.indices {
            let item = result.items[index]
            if let reference = item.iconReference {
                let url = URLComponents(string: reference)
                if !["http", "https"].contains(url?.scheme?.lowercased() ?? "") || url?.host?.isEmpty != false {
                    result.items[index].iconReference = nil
                }
            }
            if case .website = item.target {
                result.items[index].isAvailable = true
            } else if let existing = localByID[item.id], existing.target == item.target,
                      existing.bookmarkData != nil {
                result.items[index].isAvailable = existing.isAvailable
            } else {
                result.items[index].isAvailable = false
            }
        }
        for category in LaunchItemCategory.allCases {
            let itemPages = result.items.filter { $0.category == category && $0.groupID == nil }.map(\.pageIndex)
            let groupPages = result.groups.filter { $0.category == category }.map(\.pageIndex)
            let lastPage = (itemPages + groupPages).max() ?? 0
            result.selectedPages[category] = min(max(local.selectedPages[category, default: 0], 0), lastPage)
        }
        return result
    }
}

enum ConfigurationImportError: LocalizedError {
    case unreadableLocalData
    case backupFailed(String)
    case importFailed(String, URL)
    case rollbackFailed(String, String, URL)

    var errorDescription: String? {
        switch self {
        case .unreadableLocalData:
            "当前启动台数据读取失败。为避免覆盖原文件，已停止导出或导入，请先恢复本机数据。"
        case let .backupFailed(message):
            "无法创建导入前的恢复备份，未修改当前配置：\(message)"
        case let .importFailed(message, url):
            "导入失败，原配置已保留或恢复：\(message)\n恢复备份：\(url.path)"
        case let .rollbackFailed(message, rollback, url):
            "导入失败：\(message)\n恢复原配置时也遇到问题：\(rollback)\n请保留并手动导入恢复备份：\(url.path)"
        }
    }
}
