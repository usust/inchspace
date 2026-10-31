import XCTest
@testable import inchspace

final class PortableDataTests: XCTestCase {
    func testPortableCopyRemovesDeviceAuthorizationAndTransientState() {
        let item = LaunchItem(
            name: "Projects",
            category: .directory,
            target: .directory(path: "/Users/example/Projects"),
            pageIndex: 2,
            orderIndex: 3,
            isAvailable: false,
            bookmarkData: Data([1, 2, 3])
        )
        let local = LaunchpadLibrary(
            items: [item],
            selectedPages: [.directory: 2]
        )

        let cloud = local.portableCopy()

        XCTAssertNil(cloud.items.first?.bookmarkData)
        XCTAssertEqual(cloud.items.first?.isAvailable, true)
        XCTAssertTrue(cloud.selectedPages.isEmpty)
        XCTAssertEqual(cloud.items.first?.pageIndex, 2)
        XCTAssertEqual(cloud.items.first?.orderIndex, 3)
    }

    func testImportedLayoutRestoresMatchingLocalDeviceState() {
        let id = UUID()
        let target = LaunchTarget.directory(path: "/Users/example/Projects")
        let localItem = LaunchItem(
            id: id,
            name: "Old name",
            category: .directory,
            target: target,
            isAvailable: false,
            bookmarkData: Data([4, 5, 6])
        )
        let remoteItem = LaunchItem(
            id: id,
            name: "New name",
            category: .directory,
            target: target,
            pageIndex: 1,
            orderIndex: 4,
            bookmarkData: Data([9, 9, 9])
        )
        let local = LaunchpadLibrary(
            items: [localItem],
            selectedPages: [.directory: 3]
        )
        let remote = LaunchpadLibrary(
            items: [remoteItem],
            selectedPages: [.directory: 1]
        )

        let restored = remote.restoringDeviceState(from: local)

        XCTAssertEqual(restored.items.first?.name, "New name")
        XCTAssertEqual(restored.items.first?.pageIndex, 1)
        XCTAssertEqual(restored.items.first?.bookmarkData, Data([4, 5, 6]))
        XCTAssertEqual(restored.items.first?.isAvailable, false)
        XCTAssertEqual(restored.selectedPages, [.directory: 3])
    }

    func testImportedChangedTargetDoesNotReuseOldAuthorization() {
        let id = UUID()
        let local = LaunchpadLibrary(items: [
            LaunchItem(
                id: id,
                name: "Projects",
                category: .directory,
                target: .directory(path: "/Users/example/Old"),
                isAvailable: false,
                bookmarkData: Data([1, 2, 3])
            ),
        ])
        let remote = LaunchpadLibrary(items: [
            LaunchItem(
                id: id,
                name: "Projects",
                category: .directory,
                target: .directory(path: "/Users/example/New"),
                bookmarkData: Data([9, 9, 9])
            ),
        ])

        let restored = remote.restoringDeviceState(from: local)

        XCTAssertNil(restored.items.first?.bookmarkData)
        XCTAssertEqual(restored.items.first?.isAvailable, true)
    }
}
