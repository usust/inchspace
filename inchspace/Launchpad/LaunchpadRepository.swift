//
//  LaunchpadRepository.swift
//  inchspace
//
//  工作台唯一数据源：校验、修改、事务快照与合并持久化都集中在此处。
//

import Combine
import Foundation

@MainActor
final class LaunchpadRepository: ObservableObject {
    enum RepositoryError: LocalizedError {
        case duplicateItem
        case itemNotFound
        case invalidGroupOperation

        var errorDescription: String? {
            switch self {
            case .duplicateItem: "这个快捷方式已经在工作台中。"
            case .itemNotFound: "快捷方式已不存在。"
            case .invalidGroupOperation: "当前项目无法完成分组操作。"
            }
        }
    }

    @Published private(set) var library: LaunchpadLibrary
    @Published private(set) var persistenceError: String?

    private let persistence: LaunchpadPersistenceService
    private let syncManager: ICloudSyncManager?
    private var interactiveSnapshot: LaunchpadLibrary?
    private var pendingSaveTask: Task<Void, Never>?

    init(
        persistence: LaunchpadPersistenceService? = nil,
        syncManager: ICloudSyncManager? = nil
    ) {
        let persistence = persistence ?? LaunchpadPersistenceService()
        self.persistence = persistence
        self.syncManager = syncManager
        do {
            let loaded = try persistence.load()
            let source = loaded ?? Self.defaultLibrary()
            let repaired = Self.validated(source)
            library = repaired
            if loaded != nil, source.version != LaunchpadLibrary.currentVersion || source != repaired {
                do {
                    try persistence.save(repaired)
                } catch {
                    persistenceError = "布局迁移成功，但暂时无法保存：\(error.localizedDescription)"
                }
            }
        } catch {
            library = Self.defaultLibrary()
            persistenceError = "布局读取失败，已恢复默认内容：\(error.localizedDescription)"
        }
    }

    func startCloudSync() async {
        guard syncManager != nil else { return }
        await synchronizeWithCloud(allowsUpload: true)
    }

    func refreshCloudData() async {
        guard syncManager != nil else { return }
        await synchronizeWithCloud(allowsUpload: false)
    }

    func item(withID id: UUID) -> LaunchItem? {
        library.items.first { $0.id == id }
    }

    func group(withID id: UUID) -> LaunchGroup? {
        library.groups.first { $0.id == id }
    }

    func groups(in category: LaunchItemCategory) -> [LaunchGroup] {
        library.groups.filter { $0.category == category }
    }

    func items(in groupID: UUID) -> [LaunchItem] {
        guard let group = group(withID: groupID) else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: library.items.map { ($0.id, $0) })
        return group.itemIDs.compactMap { byID[$0] }
    }

    func rootEntries(in category: LaunchItemCategory) -> [LaunchEntry] {
        let items = library.items
            .filter { $0.category == category && $0.groupID == nil }
            .map(LaunchEntry.item)
        let groups = library.groups
            .filter { $0.category == category }
            .map(LaunchEntry.group)

        return (items + groups).sorted(by: Self.entrySort)
    }

    func pages(in category: LaunchItemCategory, capacity: Int) -> [LaunchPage] {
        let entryPages = LaunchpadLayoutEngine.pages(from: rootEntries(in: category), capacity: capacity)
        return entryPages.map(LaunchPage.init(entries:))
    }

    func selectedPage(for category: LaunchItemCategory, capacity: Int) -> Int {
        let lastIndex = max(pages(in: category, capacity: capacity).count - 1, 0)
        return min(max(library.selectedPages[category, default: 0], 0), lastIndex)
    }

    func setSelectedPage(_ page: Int, for category: LaunchItemCategory, capacity: Int) {
        let lastIndex = max(pages(in: category, capacity: capacity).count - 1, 0)
        let clamped = min(max(page, 0), lastIndex)
        guard library.selectedPages[category, default: 0] != clamped else { return }
        var copy = library
        copy.selectedPages[category] = clamped
        library = copy
        scheduleSave()
    }

    func normalize(category: LaunchItemCategory, capacity: Int, persist: Bool = true) {
        let original = library
        applyRootOrder(rootEntries(in: category).map(\.id), category: category, capacity: capacity)
        clampSelectedPage(for: category, capacity: capacity)
        if persist, library != original { scheduleSave() }
    }

    func add(_ item: LaunchItem, capacity: Int) throws {
        guard !library.items.contains(where: {
            $0.id == item.id || $0.target.deduplicationKey == item.target.deduplicationKey
        }) else {
            throw RepositoryError.duplicateItem
        }

        var copy = library
        copy.items.append(item)
        library = copy
        var order = rootEntries(in: item.category).map(\.id)
        if !order.contains(item.id) { order.append(item.id) }
        applyRootOrder(order, category: item.category, capacity: capacity)
        scheduleSave()
    }

    func updateItem(
        id: UUID,
        name: String? = nil,
        target: LaunchTarget? = nil,
        iconReference: String?? = nil,
        bookmarkData: Data? = nil
    ) throws {
        guard let index = library.items.firstIndex(where: { $0.id == id }) else {
            throw RepositoryError.itemNotFound
        }

        if let target,
           library.items.contains(where: { $0.id != id && $0.target.deduplicationKey == target.deduplicationKey }) {
            throw RepositoryError.duplicateItem
        }

        var copy = library
        if let name { copy.items[index].name = name }
        if let target { copy.items[index].target = target }
        if let iconReference { copy.items[index].iconReference = iconReference }
        if let bookmarkData { copy.items[index].bookmarkData = bookmarkData }
        guard copy != library else { return }
        library = copy
        scheduleSave()
    }

    func renameItem(id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = library.items.firstIndex(where: { $0.id == id }),
              library.items[index].name != trimmed else { return }
        var copy = library
        copy.items[index].name = trimmed
        library = copy
        scheduleSave()
    }

    func renameGroup(id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = library.groups.firstIndex(where: { $0.id == id }),
              library.groups[index].name != trimmed else { return }
        var copy = library
        copy.groups[index].name = trimmed
        library = copy
        scheduleSave()
    }

    func markOpened(itemID: UUID) {
        guard let index = library.items.firstIndex(where: { $0.id == itemID }),
              !library.items[index].isAvailable else { return }
        var copy = library
        copy.items[index].isAvailable = true
        library = copy
        scheduleSave()
    }

    func markUnavailable(itemID: UUID) {
        guard let index = library.items.firstIndex(where: { $0.id == itemID }),
              library.items[index].isAvailable else { return }
        var copy = library
        copy.items[index].isAvailable = false
        library = copy
        scheduleSave()
    }

    // MARK: - Interactive transaction

    func beginInteractiveMutation() {
        guard interactiveSnapshot == nil else { return }
        interactiveSnapshot = library
    }

    func commitInteractiveMutation(category: LaunchItemCategory, capacity: Int) {
        guard interactiveSnapshot != nil else { return }
        normalize(category: category, capacity: capacity, persist: false)
        interactiveSnapshot = nil
        scheduleSave()
    }

    func cancelInteractiveMutation() {
        guard let interactiveSnapshot else { return }
        library = interactiveSnapshot
        self.interactiveSnapshot = nil
    }

    func moveRootEntry(
        id: UUID,
        toFlatIndex proposedIndex: Int,
        category: LaunchItemCategory,
        capacity: Int
    ) {
        let order = rootEntries(in: category).map(\.id)
        let moved = LaunchpadLayoutEngine.moving(order, value: id, to: proposedIndex)
        guard moved != order else { return }
        applyRootOrder(moved, category: category, capacity: capacity)
    }

    func completeGroupDrop(
        draggedID: UUID,
        targetID: UUID,
        category: LaunchItemCategory,
        capacity: Int
    ) throws {
        guard category == .application,
              draggedID != targetID,
              let draggedItem = item(withID: draggedID),
              draggedItem.groupID == nil,
              draggedItem.category == .application else {
            throw RepositoryError.invalidGroupOperation
        }

        let oldOrder = rootEntries(in: category).map(\.id)
        if let groupIndex = library.groups.firstIndex(where: { $0.id == targetID && $0.category == category }) {
            var copy = library
            guard let draggedIndex = copy.items.firstIndex(where: { $0.id == draggedID }),
                  !copy.groups[groupIndex].itemIDs.contains(draggedID) else {
                throw RepositoryError.itemNotFound
            }
            copy.items[draggedIndex].groupID = targetID
            copy.items[draggedIndex].orderIndex = copy.groups[groupIndex].itemIDs.count
            copy.groups[groupIndex].itemIDs.append(draggedID)
            Self.applyRootOrder(
                oldOrder.filter { $0 != draggedID },
                to: &copy,
                category: category,
                capacity: capacity
            )
            library = copy
            scheduleSave()
            return
        }

        guard let targetItem = item(withID: targetID),
              targetItem.groupID == nil,
              targetItem.category == category else {
            throw RepositoryError.invalidGroupOperation
        }

        let groupID = UUID()
        let newOrder = LaunchpadLayoutEngine.replacingWithGroup(
            oldOrder,
            dragged: draggedID,
            target: targetID,
            group: groupID
        )
        guard newOrder != oldOrder else { throw RepositoryError.invalidGroupOperation }

        var copy = library
        guard let draggedIndex = copy.items.firstIndex(where: { $0.id == draggedID }),
              let targetIndex = copy.items.firstIndex(where: { $0.id == targetID }) else {
            throw RepositoryError.itemNotFound
        }
        copy.items[targetIndex].groupID = groupID
        copy.items[targetIndex].orderIndex = 0
        copy.items[draggedIndex].groupID = groupID
        copy.items[draggedIndex].orderIndex = 1
        copy.groups.append(
            LaunchGroup(
                id: groupID,
                name: defaultGroupName(for: category),
                category: category,
                itemIDs: [targetID, draggedID]
            )
        )
        Self.applyRootOrder(newOrder, to: &copy, category: category, capacity: capacity)
        library = copy
        scheduleSave()
    }

    func moveItem(_ itemID: UUID, toGroup groupID: UUID, category: LaunchItemCategory, capacity: Int) {
        guard let itemIndex = library.items.firstIndex(where: { $0.id == itemID }),
              library.items[itemIndex].groupID == nil,
              library.items[itemIndex].category == category,
              let groupIndex = library.groups.firstIndex(where: {
                  $0.id == groupID && $0.category == category
              }),
              !library.groups[groupIndex].itemIDs.contains(itemID) else { return }
        let oldOrder = rootEntries(in: category).map(\.id)
        var copy = library
        copy.items[itemIndex].groupID = groupID
        copy.items[itemIndex].orderIndex = copy.groups[groupIndex].itemIDs.count
        copy.groups[groupIndex].itemIDs.append(itemID)
        Self.applyRootOrder(
            oldOrder.filter { $0 != itemID },
            to: &copy,
            category: category,
            capacity: capacity
        )
        library = copy
        scheduleSave()
    }

    func moveItemOutOfGroup(_ itemID: UUID, insertAt proposedIndex: Int, capacity: Int) {
        guard let itemIndex = library.items.firstIndex(where: { $0.id == itemID }),
              let groupID = library.items[itemIndex].groupID,
              let groupIndex = library.groups.firstIndex(where: { $0.id == groupID }) else { return }
        let category = library.items[itemIndex].category
        var rootOrder = rootEntries(in: category).map(\.id)
        var copy = library
        copy.groups[groupIndex].itemIDs.removeAll { $0 == itemID }
        copy.items[itemIndex].groupID = nil

        switch copy.groups[groupIndex].itemIDs.count {
        case 0:
            copy.groups.remove(at: groupIndex)
            rootOrder.removeAll { $0 == groupID }
        case 1:
            let remainingItemID = copy.groups[groupIndex].itemIDs[0]
            if let remainingIndex = copy.items.firstIndex(where: { $0.id == remainingItemID }) {
                copy.items[remainingIndex].groupID = nil
            }
            copy.groups.remove(at: groupIndex)
            if let groupPosition = rootOrder.firstIndex(of: groupID) {
                rootOrder[groupPosition] = remainingItemID
            } else if !rootOrder.contains(remainingItemID) {
                rootOrder.append(remainingItemID)
            }
        default:
            for (index, remainingItemID) in copy.groups[groupIndex].itemIDs.enumerated() {
                if let remainingIndex = copy.items.firstIndex(where: { $0.id == remainingItemID }) {
                    copy.items[remainingIndex].orderIndex = index
                }
            }
        }

        rootOrder.removeAll { $0 == itemID }
        rootOrder.insert(itemID, at: min(max(proposedIndex, 0), rootOrder.count))
        Self.applyRootOrder(rootOrder, to: &copy, category: category, capacity: capacity)
        library = copy
        scheduleSave()
    }

    func reorderItem(in groupID: UUID, itemID: UUID, to proposedIndex: Int) {
        guard let groupIndex = library.groups.firstIndex(where: { $0.id == groupID }) else { return }
        let oldOrder = library.groups[groupIndex].itemIDs
        let newOrder = LaunchpadLayoutEngine.moving(oldOrder, value: itemID, to: proposedIndex)
        guard newOrder != oldOrder else { return }
        var copy = library
        copy.groups[groupIndex].itemIDs = newOrder
        for (index, id) in newOrder.enumerated() {
            if let itemIndex = copy.items.firstIndex(where: { $0.id == id }) {
                copy.items[itemIndex].orderIndex = index
            }
        }
        library = copy
    }

    func dissolveGroup(_ groupID: UUID, capacity: Int) {
        guard let group = group(withID: groupID) else { return }
        let category = group.category
        let rootOrder = rootEntries(in: category).map(\.id)
        guard let groupPosition = rootOrder.firstIndex(of: groupID) else { return }

        var copy = library
        for itemID in group.itemIDs {
            if let index = copy.items.firstIndex(where: { $0.id == itemID }) {
                copy.items[index].groupID = nil
            }
        }
        copy.groups.removeAll { $0.id == groupID }

        var newOrder = rootOrder.filter { $0 != groupID }
        newOrder.insert(contentsOf: group.itemIDs, at: min(groupPosition, newOrder.count))
        Self.applyRootOrder(newOrder, to: &copy, category: category, capacity: capacity)
        library = copy
        scheduleSave()
    }

    func deleteItem(_ itemID: UUID, capacity: Int) {
        guard let item = item(withID: itemID) else { return }
        var rootOrder = rootEntries(in: item.category).map(\.id)
        var copy = library
        if let groupID = item.groupID,
           let groupIndex = copy.groups.firstIndex(where: { $0.id == groupID }) {
            copy.groups[groupIndex].itemIDs.removeAll { $0 == itemID }
            for (index, remainingItemID) in copy.groups[groupIndex].itemIDs.enumerated() {
                if let remainingItemIndex = copy.items.firstIndex(where: { $0.id == remainingItemID }) {
                    copy.items[remainingItemIndex].orderIndex = index
                }
            }

            switch copy.groups[groupIndex].itemIDs.count {
            case 0:
                copy.groups.remove(at: groupIndex)
                rootOrder.removeAll { $0 == groupID }
            case 1:
                let remainingItemID = copy.groups[groupIndex].itemIDs[0]
                if let remainingItemIndex = copy.items.firstIndex(where: { $0.id == remainingItemID }) {
                    copy.items[remainingItemIndex].groupID = nil
                }
                copy.groups.remove(at: groupIndex)
                if let groupPosition = rootOrder.firstIndex(of: groupID) {
                    rootOrder[groupPosition] = remainingItemID
                } else {
                    rootOrder.append(remainingItemID)
                }
            default:
                break
            }
        } else {
            rootOrder.removeAll { $0 == itemID }
        }
        copy.items.removeAll { $0.id == itemID }
        Self.applyRootOrder(rootOrder, to: &copy, category: item.category, capacity: capacity)
        library = copy
        clampSelectedPage(for: item.category, capacity: capacity)
        scheduleSave()
    }

    func saveImmediately() {
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        do {
            // 若应用在拖动中暂时失活，只保存拖动前快照，避免半完成布局落盘。
            try persistence.save(interactiveSnapshot ?? library)
            persistenceError = nil
            syncManager?.scheduleUpload(interactiveSnapshot ?? library)
        } catch {
            persistenceError = "布局保存失败：\(error.localizedDescription)"
        }
    }

    // MARK: - Internals

    private func applyRootOrder(_ rawOrder: [UUID], category: LaunchItemCategory, capacity: Int) {
        var copy = library
        Self.applyRootOrder(rawOrder, to: &copy, category: category, capacity: capacity)
        if copy != library { library = copy }
    }

    private static func applyRootOrder(
        _ rawOrder: [UUID],
        to library: inout LaunchpadLibrary,
        category: LaunchItemCategory,
        capacity: Int
    ) {
        let existingOrder = rootEntries(in: library, category: category).map(\.id)
        let validIDs = Set(existingOrder)
        var order = LaunchpadLayoutEngine.removingDuplicates(rawOrder).filter { validIDs.contains($0) }
        var includedIDs = Set(order)
        for id in existingOrder where includedIDs.insert(id).inserted {
            order.append(id)
        }

        let locations = LaunchpadLayoutEngine.locations(count: order.count, capacity: capacity)
        let itemIndices = Dictionary(uniqueKeysWithValues: library.items.indices.map { (library.items[$0].id, $0) })
        let groupIndices = Dictionary(uniqueKeysWithValues: library.groups.indices.map { (library.groups[$0].id, $0) })
        for (index, id) in order.enumerated() {
            let location = locations[index]
            if let itemIndex = itemIndices[id], library.items[itemIndex].groupID == nil {
                library.items[itemIndex].pageIndex = location.pageIndex
                library.items[itemIndex].orderIndex = location.orderIndex
            } else if let groupIndex = groupIndices[id] {
                library.groups[groupIndex].pageIndex = location.pageIndex
                library.groups[groupIndex].orderIndex = location.orderIndex
                for memberID in library.groups[groupIndex].itemIDs {
                    if let itemIndex = itemIndices[memberID] {
                        library.items[itemIndex].pageIndex = location.pageIndex
                    }
                }
            }
        }
    }

    private static func rootEntries(
        in library: LaunchpadLibrary,
        category: LaunchItemCategory
    ) -> [LaunchEntry] {
        let items = library.items
            .filter { $0.category == category && $0.groupID == nil }
            .map(LaunchEntry.item)
        let groups = library.groups
            .filter { $0.category == category }
            .map(LaunchEntry.group)
        return (items + groups).sorted(by: entrySort)
    }

    private func clampSelectedPage(for category: LaunchItemCategory, capacity: Int) {
        let lastIndex = max(pages(in: category, capacity: capacity).count - 1, 0)
        let clamped = min(max(library.selectedPages[category, default: 0], 0), lastIndex)
        if library.selectedPages[category, default: 0] != clamped {
            var copy = library
            copy.selectedPages[category] = clamped
            library = copy
        }
    }

    private func scheduleSave() {
        guard interactiveSnapshot == nil else { return }
        pendingSaveTask?.cancel()
        pendingSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            self?.saveImmediately()
        }
    }

    private func synchronizeWithCloud(allowsUpload: Bool) async {
        let localDate = persistence.modificationDate
        if let remote = await syncManager?.synchronize(
            localLibrary: library,
            localModifiedAt: localDate,
            allowsUpload: allowsUpload
        ) {
            let repaired = Self.validated(remote)
            library = repaired
            do {
                try persistence.save(repaired)
                persistenceError = nil
            } catch {
                persistenceError = "iCloud 数据已获取，但暂时无法保存到本机：\(error.localizedDescription)"
            }
        }
    }

    private func defaultGroupName(for category: LaunchItemCategory) -> String {
        switch category {
        case .application: "程序组"
        case .directory: "目录组"
        case .website: "网站组"
        }
    }

    private static func entrySort(_ lhs: LaunchEntry, _ rhs: LaunchEntry) -> Bool {
        if lhs.pageIndex != rhs.pageIndex { return lhs.pageIndex < rhs.pageIndex }
        if lhs.orderIndex != rhs.orderIndex { return lhs.orderIndex < rhs.orderIndex }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func validated(_ source: LaunchpadLibrary) -> LaunchpadLibrary {
        var result = source
        result.version = LaunchpadLibrary.currentVersion

        var itemIDs = Set<UUID>()
        var targetKeys = Set<String>()
        result.items = result.items.filter { item in
            itemIDs.insert(item.id).inserted && targetKeys.insert(item.target.deduplicationKey).inserted
        }

        let itemsByID = Dictionary(uniqueKeysWithValues: result.items.map { ($0.id, $0) })
        var claimedItemIDs = Set<UUID>()
        var groupIDs = Set<UUID>()
        result.groups = result.groups.compactMap { group in
            guard groupIDs.insert(group.id).inserted else { return nil }
            var copy = group
            copy.itemIDs = LaunchpadLayoutEngine.removingDuplicates(group.itemIDs).filter { id in
                guard let item = itemsByID[id], item.category == group.category else { return false }
                return claimedItemIDs.insert(id).inserted
            }
            return copy.itemIDs.isEmpty ? nil : copy
        }

        // A folder with one surviving item has no useful grouping semantics.
        // Collapse it at its saved root position during repair/migration.
        let singleItemGroups = result.groups.filter { $0.itemIDs.count == 1 }
        for group in singleItemGroups {
            guard let itemID = group.itemIDs.first,
                  let itemIndex = result.items.firstIndex(where: { $0.id == itemID }) else { continue }
            result.items[itemIndex].groupID = nil
            result.items[itemIndex].pageIndex = group.pageIndex
            result.items[itemIndex].orderIndex = group.orderIndex
        }
        let singleItemGroupIDs = Set(singleItemGroups.map(\.id))
        result.groups.removeAll { singleItemGroupIDs.contains($0.id) }

        let membership = Dictionary(uniqueKeysWithValues: result.groups.flatMap { group in
            group.itemIDs.map { ($0, group.id) }
        })
        for index in result.items.indices {
            result.items[index].groupID = membership[result.items[index].id]
        }
        for group in result.groups {
            for (orderIndex, itemID) in group.itemIDs.enumerated() {
                if let itemIndex = result.items.firstIndex(where: { $0.id == itemID }) {
                    result.items[itemIndex].pageIndex = group.pageIndex
                    result.items[itemIndex].orderIndex = orderIndex
                }
            }
        }
        return result
    }

    private static func defaultLibrary() -> LaunchpadLibrary {
        let applications: [(String, String)] = [
            ("Safari", "com.apple.Safari"),
            ("备忘录", "com.apple.Notes"),
            ("日历", "com.apple.iCal"),
            ("文本编辑", "com.apple.TextEdit"),
            ("预览", "com.apple.Preview"),
            ("系统设置", "com.apple.systempreferences"),
            ("App Store", "com.apple.AppStore"),
        ]
        let items = applications.enumerated().map { index, app in
            LaunchItem(
                name: app.0,
                category: .application,
                target: .application(bundleIdentifier: app.1, path: nil),
                orderIndex: index
            )
        }
        return LaunchpadLibrary(items: items)
    }
}
