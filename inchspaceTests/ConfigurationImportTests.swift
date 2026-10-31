import XCTest
@testable import inchspace

@MainActor
final class ConfigurationImportTests: XCTestCase {
    private struct Fixture {
        let directory: URL
        let defaults: UserDefaults
        let suite: String
        let persistence: LaunchpadPersistenceService
        let repository: LaunchpadRepository
        let preferences: AppWindowPreferences

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            suite = "ConfigurationImportTests.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suite)!
            persistence = LaunchpadPersistenceService(fileURL: directory.appendingPathComponent("library.json"))
            repository = LaunchpadRepository(persistence: persistence)
            preferences = AppWindowPreferences(defaults: defaults)
        }

        func cleanUp() {
            repository.saveImmediately()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }

        var recoveryDirectory: URL { directory.appendingPathComponent("backups") }
    }

    private enum TestError: Error { case failed }

    private func document() -> ConfigurationBackup {
        ConfigurationBackup(
            library: LaunchpadLibrary(items: [
                LaunchItem(name: "Imported", category: .website, target: .website(url: "https://example.com")),
            ]),
            preferences: PortableAppPreferences(hidesAfterOpen: false, windowPosition: .screenCenter),
            appVersion: "test"
        )
    }

    func testSnapshotIncludesPendingEditsAndDoesNotMutateState() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let item = LaunchItem(name: "Pending", category: .website, target: .website(url: "https://pending.example"))
        try fixture.repository.add(item, capacity: 20)
        let coordinator = ConfigurationImportCoordinator(recoveryDirectory: fixture.recoveryDirectory)
        let snapshot = try coordinator.snapshot(repository: fixture.repository, preferences: fixture.preferences)
        XCTAssertEqual(snapshot.library.items.map(\.id), [item.id])
        XCTAssertNil(try fixture.persistence.load())
        _ = try ConfigurationBackup.decode(snapshot.encoded())
        XCTAssertEqual(fixture.repository.library.items.map(\.id), [item.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.recoveryDirectory.path))
    }

    func testImportCreatesRestorableBackupAndPreservesDevicePreferences() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let oldItem = LaunchItem(name: "Old", category: .website, target: .website(url: "https://old.example"))
        try fixture.repository.add(oldItem, capacity: 20)
        fixture.preferences.setShowsDockIcon(false)
        fixture.preferences.setShowsMenuBarIcon(false)
        fixture.defaults.set("untouched", forKey: "otherModule")
        let oldPreferences = fixture.preferences.portablePreferences
        let coordinator = ConfigurationImportCoordinator(recoveryDirectory: fixture.recoveryDirectory)
        let result = try coordinator.importConfiguration(document(), repository: fixture.repository, preferences: fixture.preferences)
        XCTAssertEqual(result.itemCount, 1)
        XCTAssertEqual(fixture.repository.library.items.first?.name, "Imported")
        XCTAssertEqual(try fixture.persistence.load(), fixture.repository.library)
        XCTAssertFalse(fixture.preferences.hidesAfterOpen)
        XCTAssertEqual(AppWindowPreferences(defaults: fixture.defaults).position, .screenCenter)
        XCTAssertFalse(fixture.preferences.showsDockIcon)
        XCTAssertFalse(fixture.preferences.showsMenuBarIcon)
        XCTAssertEqual(fixture.defaults.string(forKey: "otherModule"), "untouched")
        let recovery = try ConfigurationBackup.read(from: result.recoveryURL)
        XCTAssertEqual(recovery.library.items.map(\.id), [oldItem.id])
        XCTAssertEqual(recovery.preferences, oldPreferences)
        _ = try coordinator.importConfiguration(recovery, repository: fixture.repository, preferences: fixture.preferences)
        XCTAssertEqual(fixture.repository.library.items.map(\.id), [oldItem.id])
        XCTAssertEqual(fixture.preferences.portablePreferences, oldPreferences)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.recoveryDirectory.path).count, 2)
    }

    func testRecoveryWriteFailureLeavesCurrentStateUnchanged() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.repository.saveImmediately()
        let dataBefore = try Data(contentsOf: fixture.persistence.fileURL)
        let original = fixture.preferences.portablePreferences
        let coordinator = ConfigurationImportCoordinator(
            recoveryDirectory: fixture.recoveryDirectory,
            writeRecovery: { _, _ in throw TestError.failed }
        )
        XCTAssertThrowsError(try coordinator.importConfiguration(document(), repository: fixture.repository, preferences: fixture.preferences))
        XCTAssertTrue(fixture.repository.library.items.isEmpty)
        XCTAssertEqual(fixture.preferences.portablePreferences, original)
        XCTAssertEqual(try Data(contentsOf: fixture.persistence.fileURL), dataBefore)
    }

    func testLibraryWriteFailureDoesNotApplyPreferences() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let original = fixture.preferences.portablePreferences
        try FileManager.default.createDirectory(at: fixture.persistence.fileURL, withIntermediateDirectories: true)
        let coordinator = ConfigurationImportCoordinator(recoveryDirectory: fixture.recoveryDirectory)
        XCTAssertThrowsError(try coordinator.importConfiguration(document(), repository: fixture.repository, preferences: fixture.preferences))
        XCTAssertTrue(fixture.repository.library.items.isEmpty)
        XCTAssertEqual(fixture.preferences.portablePreferences, original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.recoveryDirectory.path).count, 1)
    }

    func testPartialPreferencesFailureRestoresLibraryIncludingAuthorization() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let item = LaunchItem(
            name: "Local", category: .directory, target: .directory(path: "/tmp/local"),
            bookmarkData: Data([1, 2, 3])
        )
        try fixture.repository.add(item, capacity: 20)
        let original = fixture.repository.library
        let oldPreferences = fixture.preferences.portablePreferences
        var calls = 0
        let coordinator = ConfigurationImportCoordinator(
            recoveryDirectory: fixture.recoveryDirectory,
            applyPreferences: { preferences, value in
                preferences.applyPortablePreferences(value)
                calls += 1
                if calls == 1 { throw TestError.failed }
            }
        )
        XCTAssertThrowsError(try coordinator.importConfiguration(document(), repository: fixture.repository, preferences: fixture.preferences))
        XCTAssertEqual(fixture.repository.library, original)
        XCTAssertEqual(try fixture.persistence.load(), original)
        XCTAssertEqual(fixture.preferences.portablePreferences, oldPreferences)
        XCTAssertEqual(calls, 2)
    }

    func testRollbackFailureReportsRecoveryLocation() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let coordinator = ConfigurationImportCoordinator(
            recoveryDirectory: fixture.recoveryDirectory,
            applyPreferences: { _, _ in throw TestError.failed }
        )
        XCTAssertThrowsError(try coordinator.importConfiguration(document(), repository: fixture.repository, preferences: fixture.preferences)) { error in
            guard case ConfigurationImportError.rollbackFailed(_, _, let recoveryURL) = error else {
                return XCTFail("Expected rollback failure, got \(error)")
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: recoveryURL.path))
        }
    }

    func testPendingSaveCannotOverwriteImportedConfiguration() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.repository.add(
            LaunchItem(name: "Pending", category: .website, target: .website(url: "https://old.example")),
            capacity: 20
        )
        let coordinator = ConfigurationImportCoordinator(recoveryDirectory: fixture.recoveryDirectory)
        _ = try coordinator.importConfiguration(document(), repository: fixture.repository, preferences: fixture.preferences)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(try fixture.persistence.load()?.items.first?.name, "Imported")
    }

    func testPreparedLibraryKeepsOnlyMatchingAuthorizationAndClampsPage() {
        let old = LaunchItem(
            name: "Local", category: .directory, target: .directory(path: "/tmp/local"),
            bookmarkData: Data([1])
        )
        let local = LaunchpadLibrary(items: [old], selectedPages: [.directory: 8])
        var changed = old
        changed.target = .directory(path: "/tmp/changed")
        let changedResult = ConfigurationImportCoordinator.preparedLibrary(LaunchpadLibrary(items: [changed]), local: local)
        XCTAssertNil(changedResult.items[0].bookmarkData)
        XCTAssertFalse(changedResult.items[0].isAvailable)
        XCTAssertEqual(changedResult.selectedPages[.directory], 0)
        let matchedResult = ConfigurationImportCoordinator.preparedLibrary(LaunchpadLibrary(items: [old]), local: local)
        XCTAssertEqual(matchedResult.items[0].bookmarkData, Data([1]))
        XCTAssertTrue(matchedResult.items[0].isAvailable)
    }

    func testRebindingImportedTargetPreservesNameGroupAndPosition() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let groupID = UUID()
        let first = LaunchItem(name: "Work", category: .directory, target: .directory(path: "/old/work"), groupID: groupID, isAvailable: false)
        let second = LaunchItem(name: "Notes", category: .directory, target: .directory(path: "/old/notes"), orderIndex: 1, groupID: groupID, isAvailable: false)
        let group = LaunchGroup(id: groupID, name: "Projects", category: .directory, itemIDs: [first.id, second.id])
        try fixture.repository.replaceConfiguration(LaunchpadLibrary(items: [first, second], groups: [group]))
        try fixture.repository.updateItem(id: first.id, target: .directory(path: "/new/work"), bookmarkData: Data([7]))
        let rebound = try XCTUnwrap(fixture.repository.item(withID: first.id))
        XCTAssertEqual(rebound.name, first.name)
        XCTAssertEqual(rebound.groupID, groupID)
        XCTAssertEqual(rebound.pageIndex, first.pageIndex)
        XCTAssertEqual(rebound.orderIndex, first.orderIndex)
        XCTAssertEqual(rebound.bookmarkData, Data([7]))
        XCTAssertFalse(rebound.isAvailable)
        XCTAssertEqual(fixture.repository.library.groups, [group])
    }

    func testImportedLocalIconReferenceFallsBackWithoutAccessingFile() {
        let item = LaunchItem(
            name: "Website", category: .website, target: .website(url: "https://example.com"),
            iconReference: "file:///tmp/private-image.png"
        )
        let result = ConfigurationImportCoordinator.preparedLibrary(LaunchpadLibrary(items: [item]), local: LaunchpadLibrary())
        XCTAssertNil(result.items[0].iconReference)
        XCTAssertTrue(result.items[0].isAvailable)
    }

    func testUnreadableLocalDataCannotBeOverwrittenByBackupOrImport() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let corrupt = Data("not json".utf8)
        try corrupt.write(to: fixture.persistence.fileURL)
        let repository = LaunchpadRepository(persistence: fixture.persistence)
        let coordinator = ConfigurationImportCoordinator(recoveryDirectory: fixture.recoveryDirectory)
        XCTAssertThrowsError(try coordinator.snapshot(repository: repository, preferences: fixture.preferences))
        XCTAssertThrowsError(try coordinator.importConfiguration(document(), repository: repository, preferences: fixture.preferences))
        repository.saveImmediately()
        XCTAssertEqual(try Data(contentsOf: fixture.persistence.fileURL), corrupt)
    }
}
