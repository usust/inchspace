import Darwin
import Foundation

/// 可移植的本地配置快照；不携带当前设备的授权、可用性或选中页面。
struct ConfigurationBackup: Codable {
    static let fileExtension = "inchspacebackup"
    nonisolated static let maximumFileSize = 10 * 1024 * 1024
    private static let maximumItems = 10_000
    private static let formatIdentifier = "inchspace.configuration-backup"
    private static let sections = ["library", "preferences"]

    let exportedAt: Date
    let appVersion: String
    private let payload: Payload

    var library: LaunchpadLibrary { payload.library.model }
    var preferences: PortableAppPreferences { payload.preferences.model }

    init(library: LaunchpadLibrary, preferences: PortableAppPreferences, appVersion: String, exportedAt: Date = Date()) {
        self.exportedAt = exportedAt
        self.appVersion = appVersion
        payload = Payload(library: LibraryDTO(library), preferences: PreferencesDTO(preferences))
    }

    private enum CodingKeys: String, CodingKey {
        case format, schemaVersion, includedSections, exportedAt, appVersion, payload
    }

    init(from decoder: Decoder) throws {
        do {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            guard try values.decode(String.self, forKey: .format) == Self.formatIdentifier else {
                throw BackupError.invalid("文件格式标识不正确")
            }
            guard try values.decode(Int.self, forKey: .schemaVersion) == 1 else {
                throw BackupError.invalid("不支持此备份版本")
            }
            let sections = try values.decode([String].self, forKey: .includedSections)
            guard sections.count == Self.sections.count, Set(sections) == Set(Self.sections) else {
                throw BackupError.invalid("备份包含的配置分区不正确")
            }
            exportedAt = try values.decode(Date.self, forKey: .exportedAt)
            appVersion = try values.decode(String.self, forKey: .appVersion)
            payload = try values.decode(Payload.self, forKey: .payload)
            try validateContents()
        } catch let error as BackupError {
            throw error
        } catch {
            throw BackupError.invalid("配置数据缺失或格式不正确")
        }
    }

    func encode(to encoder: Encoder) throws {
        try validateContents()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(Self.formatIdentifier, forKey: .format)
        try values.encode(1, forKey: .schemaVersion)
        try values.encode(Self.sections, forKey: .includedSections)
        try values.encode(exportedAt, forKey: .exportedAt)
        try values.encode(appVersion, forKey: .appVersion)
        try values.encode(payload, forKey: .payload)
    }

    func encoded() throws -> Data {
        do {
            let data = try LaunchpadJSONCodec.encode(self)
            guard data.count <= Self.maximumFileSize else { throw BackupError.tooLarge }
            return data
        } catch let error as BackupError {
            throw error
        } catch {
            throw BackupError.invalid("无法编码配置备份")
        }
    }

    static func decode(_ data: Data) throws -> ConfigurationBackup {
        guard data.count <= maximumFileSize else { throw BackupError.tooLarge }
        do {
            return try LaunchpadJSONCodec.decode(Self.self, from: data)
        } catch let error as BackupError {
            throw error
        } catch {
            throw BackupError.invalid("配置数据缺失或格式不正确")
        }
    }

    static func read(from url: URL) throws -> ConfigurationBackup {
        try decode(readData(from: url))
    }

    /// 可在 Task.detached 中执行文件 I/O，再由调用方在主 actor 解码领域模型。
    nonisolated static func readData(from url: URL) throws -> Data {
        guard url.isFileURL else { throw BackupError.invalid("请选择本地备份文件") }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // 非阻塞打开后检查同一个描述符，避免 FIFO 阻塞及检查/打开之间的替换竞态。
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw BackupError.invalid("无法打开备份文件") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw BackupError.invalid("备份必须是普通文件")
        }
        guard info.st_size <= maximumFileSize else { throw BackupError.tooLarge }
        do {
            var data = Data()
            while data.count <= maximumFileSize {
                let count = min(64 * 1024, maximumFileSize + 1 - data.count)
                guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else { break }
                data.append(chunk)
            }
            guard data.count <= maximumFileSize else { throw BackupError.tooLarge }
            return data
        } catch let error as BackupError {
            throw error
        } catch {
            throw BackupError.invalid("无法读取备份文件")
        }
    }

    func write(to url: URL) throws {
        guard url.isFileURL else { throw BackupError.invalid("请选择本地备份位置") }
        let data = try encoded()
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw BackupError.invalid("无法写入备份文件")
        }
    }

    private func validateContents() throws {
        guard exportedAt.timeIntervalSince1970.isFinite else {
            throw BackupError.invalid("导出时间无效")
        }
        guard payload.library.version == LaunchpadLibrary.currentVersion,
              payload.preferences.version == PortableAppPreferences.currentVersion else {
            throw BackupError.invalid("不支持此配置数据版本")
        }
        try Self.validate(library: library)
    }

    static func validate(library: LaunchpadLibrary) throws {
        guard library.version == LaunchpadLibrary.currentVersion else {
            throw BackupError.invalid("不支持此工作台数据版本")
        }
        guard library.items.count <= maximumItems, library.groups.count <= maximumItems / 2 else {
            throw BackupError.invalid("备份中的项目或分组过多")
        }
        var identifiers = Set<UUID>()
        var targets = Set<String>()
        var items: [UUID: LaunchItem] = [:]
        for item in library.items {
            guard identifiers.insert(item.id).inserted else { throw BackupError.invalid("项目标识重复") }
            guard targets.insert(item.target.deduplicationKey).inserted else { throw BackupError.invalid("快捷方式目标重复") }
            try validatePosition(page: item.pageIndex, order: item.orderIndex)
            switch (item.category, item.target) {
            case let (.website, .website(value)):
                guard let url = URLComponents(string: value),
                      let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
                      let host = url.host, !host.isEmpty else {
                    throw BackupError.invalid("网站必须使用带有主机名的 HTTP 或 HTTPS 地址")
                }
            case let (.directory, .directory(path)):
                try validatePath(path)
            case let (.application, .application(identifier, path)):
                if let path { try validatePath(path) }
                guard path != nil || !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw BackupError.invalid("程序缺少路径和标识")
                }
            default:
                throw BackupError.invalid("项目类别与目标不一致")
            }
            items[item.id] = item
        }
        var memberships: [UUID: UUID] = [:]
        for group in library.groups {
            guard identifiers.insert(group.id).inserted else { throw BackupError.invalid("分组或项目标识重复") }
            try validatePosition(page: group.pageIndex, order: group.orderIndex)
            guard group.itemIDs.count >= 2, group.itemIDs.count <= maximumItems else {
                throw BackupError.invalid("分组成员数量不正确")
            }
            for (order, id) in group.itemIDs.enumerated() {
                guard memberships.updateValue(group.id, forKey: id) == nil,
                      let item = items[id], item.groupID == group.id,
                      item.category == group.category,
                      item.pageIndex == group.pageIndex, item.orderIndex == order else {
                    throw BackupError.invalid("分组成员引用、类别或布局不一致")
                }
            }
        }
        for item in library.items where item.groupID != memberships[item.id] {
            throw BackupError.invalid("项目的分组引用不一致")
        }
        // 根项目允许稀疏或相同布局位置：布局引擎会按容量重新排列，不能拒绝合法旧布局。
    }

    private static func validatePosition(page: Int, order: Int) throws {
        guard (0..<maximumItems).contains(page), (0..<maximumItems).contains(order) else {
            throw BackupError.invalid("页面或排序位置超出范围")
        }
    }

    private static func validatePath(_ path: String) throws {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else {
            throw BackupError.invalid("文件路径必须是绝对路径")
        }
    }

    private struct Payload: Codable {
        let library: LibraryDTO
        let preferences: PreferencesDTO
    }

    private struct LibraryDTO: Codable {
        let version: Int
        let items: [ItemDTO]
        let groups: [GroupDTO]

        init(_ library: LaunchpadLibrary) {
            version = library.version
            items = library.items.map { ItemDTO($0) }
            groups = library.groups.map { GroupDTO($0) }
        }

        var model: LaunchpadLibrary {
            LaunchpadLibrary(version: version, items: items.map(\.model), groups: groups.map(\.model))
        }
    }

    private struct ItemDTO: Codable {
        let id: UUID
        let name: String
        let category: LaunchItemCategory
        let target: TargetDTO
        let iconReference: String?
        let pageIndex: Int
        let orderIndex: Int
        let groupID: UUID?

        init(_ item: LaunchItem) {
            id = item.id
            name = item.name
            category = item.category
            target = TargetDTO(item.target)
            iconReference = item.iconReference
            pageIndex = item.pageIndex
            orderIndex = item.orderIndex
            groupID = item.groupID
        }

        var model: LaunchItem {
            LaunchItem(id: id, name: name, category: category, target: target.model,
                       iconReference: iconReference, pageIndex: pageIndex, orderIndex: orderIndex,
                       groupID: groupID, isAvailable: category == .website, bookmarkData: nil)
        }
    }

    private enum TargetDTO: Codable {
        case application(bundleIdentifier: String, path: String?)
        case directory(path: String)
        case website(url: String)

        init(_ target: LaunchTarget) {
            switch target {
            case let .application(identifier, path): self = .application(bundleIdentifier: identifier, path: path)
            case let .directory(path): self = .directory(path: path)
            case let .website(url): self = .website(url: url)
            }
        }

        var model: LaunchTarget {
            switch self {
            case let .application(identifier, path): .application(bundleIdentifier: identifier, path: path)
            case let .directory(path): .directory(path: path)
            case let .website(url): .website(url: url)
            }
        }
    }

    private struct GroupDTO: Codable {
        let id: UUID
        let name: String
        let category: LaunchItemCategory
        let pageIndex: Int
        let orderIndex: Int
        let itemIDs: [UUID]

        init(_ group: LaunchGroup) {
            id = group.id
            name = group.name
            category = group.category
            pageIndex = group.pageIndex
            orderIndex = group.orderIndex
            itemIDs = group.itemIDs
        }

        var model: LaunchGroup {
            LaunchGroup(id: id, name: name, category: category, pageIndex: pageIndex,
                        orderIndex: orderIndex, itemIDs: itemIDs)
        }
    }

    private struct PreferencesDTO: Codable {
        let version: Int
        let hidesAfterOpen: Bool
        let windowPosition: WindowPositionPreference

        init(_ preferences: PortableAppPreferences) {
            version = preferences.version
            hidesAfterOpen = preferences.hidesAfterOpen
            windowPosition = preferences.windowPosition
        }

        var model: PortableAppPreferences {
            PortableAppPreferences(version: version, hidesAfterOpen: hidesAfterOpen, windowPosition: windowPosition)
        }
    }

    private enum BackupError: LocalizedError {
        case invalid(String)
        case tooLarge

        nonisolated var errorDescription: String? {
            switch self {
            case let .invalid(reason): "配置备份无效：\(reason)。"
            case .tooLarge: "配置备份不能超过 10 MB。"
            }
        }
    }
}
