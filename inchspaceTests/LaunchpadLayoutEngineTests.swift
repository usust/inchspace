//
//  LaunchpadLayoutEngineTests.swift
//  inchspaceTests
//

import CoreGraphics
import XCTest
@testable import inchspace

@MainActor
final class LaunchpadLayoutEngineTests: XCTestCase {
    func testDragCenterKeepsInitialGrabOffsetAfterDragBegins() async throws {
        let coordinator = LaunchpadDragCoordinator(longPressDuration: 0.01)
        let entryID = UUID()
        coordinator.beginPress(entryID: entryID, location: .zero)
        try await Task.sleep(for: .milliseconds(20))
        coordinator.beginDrag(
            entryID: entryID,
            pageIndex: 0,
            proposedIndex: 0,
            dragCenterOffset: CGSize(width: 12, height: -7)
        )

        XCTAssertEqual(
            coordinator.dragCenter(for: CGPoint(x: 100, y: 80)),
            CGPoint(x: 112, y: 73)
        )
        coordinator.updatePointer(CGPoint(x: 112, y: 73), pageIndex: 0)
        XCTAssertEqual(coordinator.dragPosition.location, CGPoint(x: 112, y: 73))
    }

    func testMoveForwardUsesInsertionInsteadOfSwap() {
        XCTAssertEqual(
            LaunchpadLayoutEngine.moving([0, 1, 2, 3], value: 3, to: 1),
            [0, 3, 1, 2]
        )
    }

    func testMoveBackwardUsesInsertionInsteadOfSwap() {
        XCTAssertEqual(
            LaunchpadLayoutEngine.moving([0, 1, 2, 3], value: 0, to: 3),
            [1, 2, 3, 0]
        )
    }

    func testMovingClampsDestinationAndSkipsUnchangedIndex() {
        XCTAssertEqual(LaunchpadLayoutEngine.moving([0, 1, 2], value: 0, to: 99), [1, 2, 0])
        XCTAssertEqual(LaunchpadLayoutEngine.moving([0, 1, 2], value: 2, to: -99), [2, 0, 1])
        XCTAssertEqual(LaunchpadLayoutEngine.moving([0, 1, 2], value: 1, to: 1), [0, 1, 2])
    }

    func testStableSlotHysteresisPreventsBoundaryOscillation() {
        let slots = [
            CGRect(x: -20, y: -20, width: 40, height: 40),
            CGRect(x: 80, y: -20, width: 40, height: 40),
        ]

        XCTAssertEqual(
            LaunchpadLayoutEngine.proposedSlotIndex(
                at: CGPoint(x: 55, y: 0),
                in: slots,
                currentIndex: 0,
                hysteresis: 10
            ),
            0
        )
        XCTAssertEqual(
            LaunchpadLayoutEngine.proposedSlotIndex(
                at: CGPoint(x: 61, y: 0),
                in: slots,
                currentIndex: 0,
                hysteresis: 10
            ),
            1
        )
        XCTAssertEqual(
            LaunchpadLayoutEngine.proposedSlotIndex(
                at: CGPoint(x: 45, y: 0),
                in: slots,
                currentIndex: 1,
                hysteresis: 10
            ),
            1
        )
        XCTAssertEqual(
            LaunchpadLayoutEngine.proposedSlotIndex(
                at: CGPoint(x: 39, y: 0),
                in: slots,
                currentIndex: 1,
                hysteresis: 10
            ),
            0
        )
    }

    func testFolderAwareReorderWaitsUntilPointerPassesTargetCenter() {
        let slots = [
            CGRect(x: -20, y: -20, width: 40, height: 40),
            CGRect(x: 80, y: -20, width: 40, height: 40),
        ]

        XCTAssertEqual(
            LaunchpadLayoutEngine.proposedSlotIndex(
                at: CGPoint(x: 100, y: 0),
                in: slots,
                currentIndex: 0,
                hysteresis: 10,
                commitFraction: 1
            ),
            0
        )
        XCTAssertEqual(
            LaunchpadLayoutEngine.proposedSlotIndex(
                at: CGPoint(x: 111, y: 0),
                in: slots,
                currentIndex: 0,
                hysteresis: 10,
                commitFraction: 1
            ),
            1
        )
    }

    func testFolderActivationFrameUsesOnlyIconCenter() {
        let cell = CGRect(x: 20, y: 40, width: 112, height: 112)
        let activation = LaunchpadLayoutEngine.folderActivationFrame(
            in: cell,
            iconSize: 68,
            activationFraction: 0.60
        )

        XCTAssertEqual(activation.width, 40.8, accuracy: 0.001)
        XCTAssertEqual(activation.height, 40.8, accuracy: 0.001)
        XCTAssertEqual(activation.midX, cell.midX, accuracy: 0.001)
        XCTAssertLessThan(activation.maxY, cell.minY + 68)
        XCTAssertFalse(activation.contains(CGPoint(x: cell.midX, y: cell.maxY - 8)))
    }

    func testShortPressDoesNotEnterEditing() {
        let coordinator = LaunchpadDragCoordinator()
        let id = UUID()
        coordinator.beginPress(entryID: id, location: .zero)

        XCTAssertEqual(coordinator.state.phase, .pressing)
        XCTAssertTrue(coordinator.finishPress(entryID: id))
        XCTAssertEqual(coordinator.state.phase, .idle)

        coordinator.beginDrag(
            entryID: id,
            pageIndex: 0,
            proposedIndex: 0
        )
        XCTAssertEqual(coordinator.state.phase, .idle)
    }

    func testMovementCancelsLongPress() async throws {
        let coordinator = LaunchpadDragCoordinator()
        let id = UUID()
        coordinator.beginPress(entryID: id, location: .zero)
        coordinator.updatePress(
            entryID: id,
            location: CGPoint(x: LaunchpadInteractionConstants.longPressMovementTolerance + 1, y: 0)
        )

        try await Task.sleep(for: .seconds(LaunchpadInteractionConstants.longPressDuration + 0.1))
        XCTAssertEqual(coordinator.state.phase, .pressing)
        XCTAssertFalse(coordinator.state.isLongPressEligible)
        XCTAssertFalse(coordinator.finishPress(entryID: id))
        XCTAssertEqual(coordinator.state.phase, .idle)
    }

    func testLongPressEntersEditingAndSuppressesOpen() async throws {
        let coordinator = LaunchpadDragCoordinator()
        let id = UUID()
        coordinator.beginPress(entryID: id, location: .zero)

        try await Task.sleep(for: .seconds(LaunchpadInteractionConstants.longPressDuration + 0.1))
        XCTAssertEqual(coordinator.state.phase, .editing)
        XCTAssertFalse(coordinator.finishPress(entryID: id))
        XCTAssertEqual(coordinator.state.phase, .editing)

        coordinator.beginDrag(
            entryID: id,
            pageIndex: 0,
            proposedIndex: 0
        )
        XCTAssertEqual(coordinator.state.phase, .dragging)
        coordinator.finishDrag()
        XCTAssertEqual(coordinator.state.phase, .editing)
        coordinator.reset()
        XCTAssertEqual(coordinator.state.phase, .idle)
    }

    func testHoverBeforeDelayDoesNotArmFolder() async throws {
        let (coordinator, _, targetID) = try await makeDraggingCoordinator(folderHoverDelay: 0.08)
        coordinator.hoverOver(candidateID: targetID, location: .zero)

        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(coordinator.state.phase, .hoveringForFolder)
        XCTAssertNil(coordinator.committedGroupTarget)
    }

    func testHoverArmsFolderThenLeavingCancelsIt() async throws {
        let (coordinator, _, targetID) = try await makeDraggingCoordinator(folderHoverDelay: 0.02)
        coordinator.hoverOver(candidateID: targetID, location: .zero)

        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(coordinator.state.phase, .folderReady)
        XCTAssertEqual(coordinator.committedGroupTarget, targetID)

        coordinator.hoverOver(candidateID: nil, location: CGPoint(x: 100, y: 100))
        XCTAssertEqual(coordinator.state.phase, .dragging)
        XCTAssertNil(coordinator.state.folderMergeTargetID)
        XCTAssertNil(coordinator.committedGroupTarget)
    }

    func testHoverMovementBeyondToleranceRestartsDelay() async throws {
        let (coordinator, _, targetID) = try await makeDraggingCoordinator(folderHoverDelay: 0.06)
        coordinator.hoverOver(candidateID: targetID, location: .zero)
        try await Task.sleep(for: .milliseconds(30))

        let movedLocation = CGPoint(
            x: LaunchpadInteractionConstants.folderMovementTolerance + 1,
            y: 0
        )
        coordinator.hoverOver(candidateID: targetID, location: movedLocation)
        try await Task.sleep(for: .milliseconds(35))

        XCTAssertEqual(coordinator.state.phase, .hoveringForFolder)
        XCTAssertEqual(coordinator.state.folderHoverStartLocation, movedLocation)
        XCTAssertNil(coordinator.committedGroupTarget)
    }

    func testMoveAcrossPagesInBothDirections() {
        let values = Array(0..<8)
        let movedToSecondPage = LaunchpadLayoutEngine.moving(values, value: 1, to: 6)
        XCTAssertEqual(LaunchpadLayoutEngine.pages(from: movedToSecondPage, capacity: 4), [[0, 2, 3, 4], [5, 6, 1, 7]])

        let movedToFirstPage = LaunchpadLayoutEngine.moving(movedToSecondPage, value: 7, to: 1)
        XCTAssertEqual(LaunchpadLayoutEngine.pages(from: movedToFirstPage, capacity: 4), [[0, 7, 2, 3], [4, 5, 6, 1]])
    }

    func testCreateAndJoinGroup() throws {
        let (repository, _) = try makeRepository(itemCount: 4)
        let items = repository.rootEntries(in: .application).compactMap { entry -> LaunchItem? in
            if case let .item(item) = entry { return item }
            return nil
        }
        let originalOrder = items.map(\.id)
        try repository.completeGroupDrop(
            draggedID: items[0].id,
            targetID: items[1].id,
            category: .application,
            capacity: 4
        )

        let group = try XCTUnwrap(repository.groups(in: .application).first)
        XCTAssertEqual(group.itemIDs, [items[1].id, items[0].id])
        XCTAssertEqual(repository.rootEntries(in: .application).count, 3)
        XCTAssertEqual(
            repository.rootEntries(in: .application).map(\.id),
            [group.id] + Array(originalOrder.dropFirst(2))
        )

        try repository.completeGroupDrop(
            draggedID: items[2].id,
            targetID: group.id,
            category: .application,
            capacity: 4
        )
        XCTAssertEqual(repository.group(withID: group.id)?.itemIDs, [items[1].id, items[0].id, items[2].id])
    }

    func testMovingOutDissolvesSingleItemGroupAutomatically() throws {
        let (repository, _) = try makeRepository(itemCount: 3)
        let ids = repository.rootEntries(in: .application).map(\.id)
        try repository.completeGroupDrop(
            draggedID: ids[0],
            targetID: ids[1],
            category: .application,
            capacity: 4
        )
        let groupID = try XCTUnwrap(repository.groups(in: .application).first?.id)

        repository.moveItemOutOfGroup(ids[0], insertAt: 0, capacity: 4)
        XCTAssertNil(repository.item(withID: ids[0])?.groupID)
        XCTAssertNil(repository.group(withID: groupID))
        XCTAssertNil(repository.item(withID: ids[1])?.groupID)
        XCTAssertEqual(repository.rootEntries(in: .application).map(\.id), [ids[0], ids[1], ids[2]])
    }

    func testDissolvingGroupKeepsMembersInGroupOrder() throws {
        let (repository, _) = try makeRepository(itemCount: 4)
        let ids = repository.rootEntries(in: .application).map(\.id)
        try repository.completeGroupDrop(
            draggedID: ids[0],
            targetID: ids[1],
            category: .application,
            capacity: 4
        )
        let groupID = try XCTUnwrap(repository.groups(in: .application).first?.id)
        try repository.completeGroupDrop(
            draggedID: ids[2],
            targetID: groupID,
            category: .application,
            capacity: 4
        )

        repository.dissolveGroup(groupID, capacity: 4)

        XCTAssertNil(repository.group(withID: groupID))
        XCTAssertEqual(repository.rootEntries(in: .application).map(\.id), [ids[1], ids[0], ids[2], ids[3]])
        XCTAssertTrue(repository.library.items.allSatisfy { $0.groupID == nil })
    }

    func testInvalidGroupingOperationsDoNotChangeData() throws {
        let (repository, _) = try makeRepository(itemCount: 4)
        let ids = repository.rootEntries(in: .application).map(\.id)
        let original = repository.library

        XCTAssertThrowsError(
            try repository.completeGroupDrop(
                draggedID: ids[0],
                targetID: ids[0],
                category: .application,
                capacity: 4
            )
        )
        XCTAssertEqual(repository.library, original)

        try repository.completeGroupDrop(
            draggedID: ids[0],
            targetID: ids[1],
            category: .application,
            capacity: 4
        )
        let group = try XCTUnwrap(repository.groups(in: .application).first)
        let grouped = repository.library
        XCTAssertThrowsError(
            try repository.completeGroupDrop(
                draggedID: group.id,
                targetID: ids[2],
                category: .application,
                capacity: 4
            )
        )
        XCTAssertEqual(repository.library, grouped)
    }

    func testSameApplicationCannotJoinGroupTwice() throws {
        let (repository, _) = try makeRepository(itemCount: 3)
        let ids = repository.rootEntries(in: .application).map(\.id)
        try repository.completeGroupDrop(
            draggedID: ids[0],
            targetID: ids[1],
            category: .application,
            capacity: 4
        )
        let groupID = try XCTUnwrap(repository.groups(in: .application).first?.id)
        try repository.completeGroupDrop(
            draggedID: ids[2],
            targetID: groupID,
            category: .application,
            capacity: 4
        )
        let grouped = repository.library

        XCTAssertThrowsError(
            try repository.completeGroupDrop(
                draggedID: ids[2],
                targetID: groupID,
                category: .application,
                capacity: 4
            )
        )
        XCTAssertEqual(repository.library, grouped)
    }

    func testWebsitesCannotCreateProgramGroups() throws {
        let websites = makeItems(count: 2, category: .website)
        let (repository, _) = try makeRepository(library: LaunchpadLibrary(items: websites))

        XCTAssertThrowsError(
            try repository.completeGroupDrop(
                draggedID: websites[0].id,
                targetID: websites[1].id,
                category: .website,
                capacity: 4
            )
        )
        XCTAssertTrue(repository.groups(in: .website).isEmpty)
        XCTAssertEqual(repository.rootEntries(in: .website).map(\.id), websites.map(\.id))
    }

    func testDeleteCompactsPagesAndRemovesEmptyPage() throws {
        let (repository, _) = try makeRepository(itemCount: 5)
        XCTAssertEqual(repository.pages(in: .application, capacity: 4).count, 2)
        let id = repository.rootEntries(in: .application).first!.id
        repository.deleteItem(id, capacity: 4)
        XCTAssertEqual(repository.pages(in: .application, capacity: 4).count, 1)
        XCTAssertEqual(repository.rootEntries(in: .application).count, 4)
    }

    func testDeletingGroupedItemDissolvesSingleItemGroupAndPreservesRemainingShortcut() throws {
        let (repository, persistence) = try makeRepository(itemCount: 3)
        let ids = repository.rootEntries(in: .application).map(\.id)
        try repository.completeGroupDrop(
            draggedID: ids[0],
            targetID: ids[1],
            category: .application,
            capacity: 4
        )
        let groupID = try XCTUnwrap(repository.groups(in: .application).first?.id)

        repository.deleteItem(ids[0], capacity: 4)

        XCTAssertNil(repository.item(withID: ids[0]))
        XCTAssertNil(repository.group(withID: groupID))
        XCTAssertNil(repository.item(withID: ids[1])?.groupID)
        XCTAssertEqual(Set(repository.rootEntries(in: .application).map(\.id)), Set([ids[1], ids[2]]))

        repository.saveImmediately()
        let restored = LaunchpadRepository(persistence: persistence)
        XCTAssertNil(restored.item(withID: ids[0]))
        XCTAssertNotNil(restored.item(withID: ids[1]))
        XCTAssertNil(restored.group(withID: groupID))
    }

    func testDeletingGroupedItemCompactsRemainingGroupOrder() throws {
        let (repository, _) = try makeRepository(itemCount: 4)
        let ids = repository.rootEntries(in: .application).map(\.id)
        try repository.completeGroupDrop(
            draggedID: ids[0],
            targetID: ids[1],
            category: .application,
            capacity: 4
        )
        let groupID = try XCTUnwrap(repository.groups(in: .application).first?.id)
        try repository.completeGroupDrop(
            draggedID: ids[2],
            targetID: groupID,
            category: .application,
            capacity: 4
        )

        repository.deleteItem(ids[1], capacity: 4)

        let remainingItems = repository.items(in: groupID)
        XCTAssertEqual(remainingItems.map(\.id), [ids[0], ids[2]])
        XCTAssertEqual(remainingItems.map(\.orderIndex), [0, 1])
    }

    func testJiggleProfileIsStableAndVariesByIdentifier() throws {
        let firstID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let secondID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))

        XCTAssertEqual(LaunchpadJiggleProfile(id: firstID), LaunchpadJiggleProfile(id: firstID))
        XCTAssertNotEqual(LaunchpadJiggleProfile(id: firstID), LaunchpadJiggleProfile(id: secondID))
    }

    func testCancelRestoresOriginalSnapshot() throws {
        let (repository, _) = try makeRepository(itemCount: 4)
        let original = repository.rootEntries(in: .application).map(\.id)
        repository.beginInteractiveMutation()
        repository.moveRootEntry(id: original[0], toFlatIndex: 3, category: .application, capacity: 4)
        XCTAssertNotEqual(repository.rootEntries(in: .application).map(\.id), original)
        repository.cancelInteractiveMutation()
        XCTAssertEqual(repository.rootEntries(in: .application).map(\.id), original)
    }

    func testCategoriesKeepIndependentOrdersAndPages() throws {
        let appItems = makeItems(count: 3, category: .application)
        let websites = makeItems(count: 3, category: .website)
        let (repository, _) = try makeRepository(library: LaunchpadLibrary(items: appItems + websites))
        let originalWebsites = repository.rootEntries(in: .website).map(\.id)
        repository.moveRootEntry(id: appItems[0].id, toFlatIndex: 2, category: .application, capacity: 2)
        repository.setSelectedPage(1, for: .application, capacity: 2)

        XCTAssertEqual(repository.rootEntries(in: .website).map(\.id), originalWebsites)
        XCTAssertEqual(repository.selectedPage(for: .website, capacity: 2), 0)
        XCTAssertEqual(repository.selectedPage(for: .application, capacity: 2), 1)
    }

    func testPersistenceRestoresLayoutAndGroups() throws {
        let (repository, persistence) = try makeRepository(itemCount: 4)
        let ids = repository.rootEntries(in: .application).map(\.id)
        try repository.completeGroupDrop(
            draggedID: ids[0],
            targetID: ids[1],
            category: .application,
            capacity: 4
        )
        repository.saveImmediately()

        let restored = LaunchpadRepository(persistence: persistence)
        XCTAssertEqual(restored.library, repository.library)
    }

    func testMissingLibraryStartsWithNoDefaultIcons() {
        let repository = LaunchpadRepository(
            persistence: LaunchpadPersistenceService(fileURL: temporaryLibraryURL())
        )

        XCTAssertTrue(repository.library.items.isEmpty)
        XCTAssertTrue(repository.library.groups.isEmpty)
        XCTAssertNil(repository.persistenceError)
    }

    func testUnreadableLibraryShowsEmptyLaunchpadInsteadOfDefaultIcons() throws {
        let fileURL = temporaryLibraryURL()
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not valid launchpad data".utf8).write(to: fileURL)

        let repository = LaunchpadRepository(
            persistence: LaunchpadPersistenceService(fileURL: fileURL)
        )

        XCTAssertTrue(repository.library.items.isEmpty)
        XCTAssertTrue(repository.library.groups.isEmpty)
        XCTAssertNotNil(repository.persistenceError)
    }

    func testPreviouslyPersistedDefaultIconsMigrateToEmptyLibrary() throws {
        let legacyApplications = [
            ("Safari", "com.apple.Safari"),
            ("备忘录", "com.apple.Notes"),
            ("日历", "com.apple.iCal"),
            ("文本编辑", "com.apple.TextEdit"),
            ("预览", "com.apple.Preview"),
            ("系统设置", "com.apple.systempreferences"),
            ("App Store", "com.apple.AppStore"),
        ]
        let items = legacyApplications.enumerated().map { index, application in
            LaunchItem(
                name: application.0,
                category: .application,
                target: .application(bundleIdentifier: application.1, path: nil),
                orderIndex: index
            )
        }
        let fileURL = temporaryLibraryURL()
        let persistence = LaunchpadPersistenceService(fileURL: fileURL)
        try persistence.save(LaunchpadLibrary(items: items))

        let repository = LaunchpadRepository(persistence: persistence)

        XCTAssertTrue(repository.library.items.isEmpty)
        XCTAssertTrue(try XCTUnwrap(persistence.load()).items.isEmpty)
    }

    func testLegacyFlatItemArrayStillLoads() throws {
        let legacyItem = makeItems(count: 1, category: .application)[0]
        let encodedItem = try JSONEncoder().encode(legacyItem)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encodedItem) as? [String: Any]
        )
        object.removeValue(forKey: "groupID")
        object["isFavorite"] = true
        object["lastOpenedAt"] = "2026-08-07T06:00:00Z"
        object.removeValue(forKey: "isAvailable")
        object.removeValue(forKey: "bookmarkData")
        let legacyData = try JSONSerialization.data(withJSONObject: [object])
        let fileURL = temporaryLibraryURL()
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try legacyData.write(to: fileURL)

        let restored = LaunchpadRepository(
            persistence: LaunchpadPersistenceService(fileURL: fileURL)
        )
        let item = try XCTUnwrap(restored.library.items.first)
        XCTAssertEqual(item.id, legacyItem.id)
        XCTAssertEqual(item.name, legacyItem.name)
        XCTAssertTrue(item.isAvailable)
        XCTAssertNil(item.groupID)
        XCTAssertEqual(restored.library.version, LaunchpadLibrary.currentVersion)
    }

    func testLegacyLibraryWithoutGroupsStillLoads() throws {
        let item = makeItems(count: 1, category: .application)[0]
        let encodedItem = try JSONEncoder().encode(item)
        let itemObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encodedItem) as? [String: Any]
        )
        let data = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "items": [itemObject],
        ])
        let fileURL = temporaryLibraryURL()
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL)

        let restored = LaunchpadRepository(
            persistence: LaunchpadPersistenceService(fileURL: fileURL)
        )
        XCTAssertEqual(restored.library.items.map(\.id), [item.id])
        XCTAssertTrue(restored.library.groups.isEmpty)
        XCTAssertTrue(restored.library.selectedPages.isEmpty)
    }

    func testDuplicateApplicationIsRejected() throws {
        let item = makeItems(count: 1, category: .application)[0]
        let (repository, _) = try makeRepository(library: LaunchpadLibrary(items: [item]))
        let duplicate = LaunchItem(
            name: "重复程序",
            category: .application,
            target: item.target
        )
        XCTAssertThrowsError(try repository.add(duplicate, capacity: 8))
    }

    func testNewItemIsAppendedToEndOfEachCategory() throws {
        for category in LaunchItemCategory.allCases {
            let existingItems = makeItems(count: 5, category: category)
            let (repository, _) = try makeRepository(
                library: LaunchpadLibrary(items: existingItems)
            )
            let newItem = makeItem(index: 99, category: category)

            try repository.add(newItem, capacity: 4)

            XCTAssertEqual(repository.rootEntries(in: category).map(\.id), existingItems.map(\.id) + [newItem.id])
            XCTAssertEqual(repository.pages(in: category, capacity: 4).last?.entries.last?.id, newItem.id)
        }
    }

    func testDuplicateIdentifierIsRejected() throws {
        let item = makeItems(count: 1, category: .application)[0]
        let (repository, _) = try makeRepository(library: LaunchpadLibrary(items: [item]))
        let duplicateID = LaunchItem(
            id: item.id,
            name: "不同网站",
            category: .website,
            target: .website(url: "https://example.org")
        )

        XCTAssertThrowsError(try repository.add(duplicateID, capacity: 8))
    }

    func testWebsiteIconCacheKeyIncludesExplicitIconAddress() {
        let target = LaunchTarget.website(url: "https://example.com")
        let first = LaunchItem(
            name: "示例",
            category: .website,
            target: target,
            iconReference: "https://example.com/first.png"
        )
        let second = LaunchItem(
            id: first.id,
            name: first.name,
            category: first.category,
            target: target,
            iconReference: "https://example.com/second.png"
        )

        XCTAssertNotEqual(first.iconCacheKey, second.iconCacheKey)
    }

    func testInvalidBookmarkAndWebsiteAreRejected() {
        XCTAssertThrowsError(try SecurityScopedBookmarkService.resolve(Data([0, 1, 2])))
        XCTAssertNil(LaunchpadOpenService.normalizedWebsiteURL(from: "://"))
        XCTAssertNil(LaunchpadOpenService.normalizedWebsiteURL(from: "ftp://example.com"))
        XCTAssertEqual(
            LaunchpadOpenService.normalizedWebsiteURL(from: "example.com")?.absoluteString,
            "https://example.com"
        )
    }

    func testRapidMovesNeverDuplicateOrLoseEntries() throws {
        let (repository, _) = try makeRepository(itemCount: 40)
        let originalIDs = Set(repository.rootEntries(in: .application).map(\.id))
        for step in 0..<200 {
            let entries = repository.rootEntries(in: .application)
            let movingID = entries[step % entries.count].id
            repository.moveRootEntry(
                id: movingID,
                toFlatIndex: (step * 7) % entries.count,
                category: .application,
                capacity: 12
            )
        }
        let finalIDs = repository.rootEntries(in: .application).map(\.id)
        XCTAssertEqual(Set(finalIDs), originalIDs)
        XCTAssertEqual(finalIDs.count, Set(finalIDs).count)
    }

    func testThreeHundredItemsPaginateWithoutLoss() throws {
        let (repository, _) = try makeRepository(itemCount: 300)
        let pages = repository.pages(in: .application, capacity: 35)
        XCTAssertEqual(pages.count, 9)
        XCTAssertEqual(pages.flatMap(\.entries).count, 300)
        XCTAssertEqual(Set(pages.flatMap(\.entries).map(\.id)).count, 300)
    }

    private func makeRepository(itemCount: Int) throws -> (LaunchpadRepository, LaunchpadPersistenceService) {
        try makeRepository(library: LaunchpadLibrary(items: makeItems(count: itemCount, category: .application)))
    }

    private func makeRepository(
        library: LaunchpadLibrary
    ) throws -> (LaunchpadRepository, LaunchpadPersistenceService) {
        let fileURL = temporaryLibraryURL()
        let persistence = LaunchpadPersistenceService(fileURL: fileURL)
        try persistence.save(library)
        return (LaunchpadRepository(persistence: persistence), persistence)
    }

    private func temporaryLibraryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("inchspace-tests-\(UUID().uuidString)")
            .appendingPathComponent("library.json")
    }

    private func makeDraggingCoordinator(
        folderHoverDelay: TimeInterval
    ) async throws -> (LaunchpadDragCoordinator, UUID, UUID) {
        let coordinator = LaunchpadDragCoordinator(
            longPressDuration: 0.01,
            folderHoverDelay: folderHoverDelay
        )
        let sourceID = UUID()
        let targetID = UUID()
        coordinator.beginPress(entryID: sourceID, location: .zero)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(coordinator.state.phase, .editing)
        XCTAssertFalse(coordinator.finishPress(entryID: sourceID))
        coordinator.beginDrag(entryID: sourceID, pageIndex: 0, proposedIndex: 0)
        XCTAssertEqual(coordinator.state.phase, .dragging)
        return (coordinator, sourceID, targetID)
    }

    private func makeItems(count: Int, category: LaunchItemCategory) -> [LaunchItem] {
        (0..<count).map { makeItem(index: $0, category: category) }
    }

    private func makeItem(index: Int, category: LaunchItemCategory) -> LaunchItem {
        let target: LaunchTarget
        switch category {
        case .application:
            target = .application(bundleIdentifier: "test.app.\(index)", path: nil)
        case .directory:
            target = .directory(path: "/tmp/test-directory-\(index)")
        case .website:
            target = .website(url: "https://example.com/\(index)")
        }
        return LaunchItem(
            name: "项目 \(index)",
            category: category,
            target: target,
            pageIndex: index / 4,
            orderIndex: index % 4
        )
    }
}
