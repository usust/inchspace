//
//  LaunchpadModels.swift
//  inchspace
//
//  工作台的可持久化领域模型。所有页面、排序和分组信息都以这里的数据为准。
//

import CoreGraphics
import Foundation

enum LaunchItemCategory: String, Codable, CaseIterable, Identifiable {
    case application
    case directory
    case website

    var id: String { rawValue }

    var title: String {
        switch self {
        case .application: "程序"
        case .directory: "目录"
        case .website: "网站"
        }
    }

    var addTitle: String {
        switch self {
        case .application: "添加程序"
        case .directory: "添加目录"
        case .website: "添加网站"
        }
    }

    var emptyDescription: String {
        switch self {
        case .application: "从“应用程序”文件夹选择常用程序"
        case .directory: "添加常用目录，以便快速在 Finder 中打开"
        case .website: "保存经常访问的网站快捷方式"
        }
    }
}

enum LaunchTarget: Codable, Hashable {
    case application(bundleIdentifier: String, path: String?)
    case directory(path: String)
    case website(url: String)

    /// 用于阻止重复快捷方式；文件路径采用标准化形式，网址忽略末尾斜杠。
    var deduplicationKey: String {
        switch self {
        case let .application(bundleIdentifier, path):
            if !bundleIdentifier.isEmpty {
                return "application:\(bundleIdentifier.lowercased())"
            }
            return "application-path:\(Self.standardizedPath(path ?? ""))"
        case let .directory(path):
            return "directory:\(Self.standardizedPath(path))"
        case let .website(url):
            return "website:\(url.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/")))"
        }
    }

    private static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

struct LaunchItem: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var category: LaunchItemCategory
    var target: LaunchTarget
    var iconReference: String?
    var pageIndex: Int
    var orderIndex: Int
    var groupID: UUID?
    var isAvailable: Bool
    /// 程序和目录由打开面板选择后保存的安全作用域书签。
    var bookmarkData: Data?

    init(
        id: UUID = UUID(),
        name: String,
        category: LaunchItemCategory,
        target: LaunchTarget,
        iconReference: String? = nil,
        pageIndex: Int = 0,
        orderIndex: Int = 0,
        groupID: UUID? = nil,
        isAvailable: Bool = true,
        bookmarkData: Data? = nil
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.target = target
        self.iconReference = iconReference
        self.pageIndex = pageIndex
        self.orderIndex = orderIndex
        self.groupID = groupID
        self.isAvailable = isAvailable
        self.bookmarkData = bookmarkData
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case category
        case target
        case iconReference
        case pageIndex
        case orderIndex
        case groupID
        case isAvailable
        case bookmarkData
    }

    /// Older flat shortcut records did not contain the launchpad-only fields.
    /// Decode them with safe defaults so upgrading never discards an existing item.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        category = try container.decode(LaunchItemCategory.self, forKey: .category)
        target = try container.decode(LaunchTarget.self, forKey: .target)
        iconReference = try container.decodeIfPresent(String.self, forKey: .iconReference)
        pageIndex = try container.decodeIfPresent(Int.self, forKey: .pageIndex) ?? 0
        orderIndex = try container.decodeIfPresent(Int.self, forKey: .orderIndex) ?? 0
        groupID = try container.decodeIfPresent(UUID.self, forKey: .groupID)
        isAvailable = try container.decodeIfPresent(Bool.self, forKey: .isAvailable) ?? true
        bookmarkData = try container.decodeIfPresent(Data.self, forKey: .bookmarkData)
    }
}

struct LaunchGroup: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var category: LaunchItemCategory
    var pageIndex: Int
    var orderIndex: Int
    var itemIDs: [UUID]

    init(
        id: UUID = UUID(),
        name: String,
        category: LaunchItemCategory,
        pageIndex: Int = 0,
        orderIndex: Int = 0,
        itemIDs: [UUID]
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.pageIndex = pageIndex
        self.orderIndex = orderIndex
        self.itemIDs = itemIDs
    }
}

enum LaunchEntry: Identifiable, Codable, Hashable {
    case item(LaunchItem)
    case group(LaunchGroup)

    var id: UUID {
        switch self {
        case let .item(item): item.id
        case let .group(group): group.id
        }
    }

    var pageIndex: Int {
        switch self {
        case let .item(item): item.pageIndex
        case let .group(group): group.pageIndex
        }
    }

    var orderIndex: Int {
        switch self {
        case let .item(item): item.orderIndex
        case let .group(group): group.orderIndex
        }
    }

    var displayName: String {
        switch self {
        case let .item(item): item.name
        case let .group(group): group.name
        }
    }
}

struct LaunchPage {
    let entries: [LaunchEntry]
}

struct LaunchpadLibrary: Codable, Equatable {
    static let currentVersion = 2

    var version: Int = Self.currentVersion
    var items: [LaunchItem] = []
    var groups: [LaunchGroup] = []
    var selectedPages: [LaunchItemCategory: Int] = [:]

    private enum CodingKeys: String, CodingKey {
        case version
        case items
        case groups
        case selectedPages
    }

    init(
        version: Int = Self.currentVersion,
        items: [LaunchItem] = [],
        groups: [LaunchGroup] = [],
        selectedPages: [LaunchItemCategory: Int] = [:]
    ) {
        self.version = version
        self.items = items
        self.groups = groups
        self.selectedPages = selectedPages
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 0
        items = try container.decodeIfPresent([LaunchItem].self, forKey: .items) ?? []
        groups = try container.decodeIfPresent([LaunchGroup].self, forKey: .groups) ?? []
        selectedPages = try container.decodeIfPresent(
            [LaunchItemCategory: Int].self,
            forKey: .selectedPages
        ) ?? [:]
    }
}

extension LaunchpadLibrary {
    /// 云端只保存可移植的数据；沙盒授权和可用性判断都属于当前设备。
    func cloudPortableCopy() -> LaunchpadLibrary {
        var copy = self
        copy.selectedPages = [:]
        for index in copy.items.indices {
            copy.items[index].bookmarkData = nil
            copy.items[index].isAvailable = true
        }
        return copy
    }

    /// 云端布局覆盖本地布局时，恢复仍与同一目标匹配的本机授权和状态。
    func restoringDeviceState(from local: LaunchpadLibrary) -> LaunchpadLibrary {
        let localItems = Dictionary(uniqueKeysWithValues: local.items.map { ($0.id, $0) })
        var copy = cloudPortableCopy()
        copy.selectedPages = local.selectedPages
        for index in copy.items.indices {
            guard let localItem = localItems[copy.items[index].id],
                  localItem.target == copy.items[index].target else { continue }
            copy.items[index].bookmarkData = localItem.bookmarkData
            copy.items[index].isAvailable = localItem.isAvailable
        }
        return copy
    }
}

struct LaunchDragState: Equatable {
    enum Phase: Equatable {
        case idle
        case pressing
        case editing
        case dragging
        case hoveringForFolder
        case folderReady
        case edgePaging
    }

    var phase: Phase = .idle
    var pressedEntryID: UUID?
    var pressStartLocation: CGPoint?
    var isLongPressEligible = false
    var draggedEntryID: UUID?
    var currentPageIndex: Int?
    var proposedIndex: Int?
    var folderMergeTargetID: UUID?
    var folderHoverStartLocation: CGPoint?
    var isDraggingFromGroup = false

    static let idle = LaunchDragState()

    var isEditing: Bool {
        switch phase {
        case .editing, .dragging, .hoveringForFolder, .folderReady, .edgePaging: true
        case .idle, .pressing: false
        }
    }

    var isDragging: Bool {
        switch phase {
        case .dragging, .hoveringForFolder, .folderReady, .edgePaging: true
        case .idle, .pressing, .editing: false
        }
    }

    var isFolderMergeReady: Bool { phase == .folderReady }
}
