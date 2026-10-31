import Darwin
import XCTest
@testable import inchspace

final class ConfigurationBackupTests: XCTestCase {
    private func backup(_ library: LaunchpadLibrary? = nil) -> ConfigurationBackup {
        ConfigurationBackup(
            library: library ?? LaunchpadLibrary(items: [website()]),
            preferences: PortableAppPreferences(hidesAfterOpen: false, windowPosition: .screenCenter),
            appVersion: "0.0.15",
            exportedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    private func website(id: UUID = UUID(), url: String = "https://example.com") -> LaunchItem {
        LaunchItem(id: id, name: "Example", category: .website, target: .website(url: url))
    }

    private func mutate(_ backup: ConfigurationBackup, _ change: (inout [String: Any]) -> Void) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: backup.encoded()) as? [String: Any])
        change(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }

    func testFormatAndBusinessDataRoundTrip() throws {
        let original = backup()
        let data = try original.encoded()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["format"] as? String, "inchspace.configuration-backup")
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(object["includedSections"] as? [String], ["library", "preferences"])
        XCTAssertEqual(ConfigurationBackup.fileExtension, "inchspacebackup")
        let decoded = try ConfigurationBackup.decode(data)
        XCTAssertEqual(decoded.library, original.library)
        XCTAssertEqual(decoded.preferences, original.preferences)
        XCTAssertEqual(decoded.exportedAt, original.exportedAt)
        XCTAssertEqual(decoded.appVersion, original.appVersion)
    }

    func testDeviceDataIsNeitherExportedNorRestored() throws {
        let local = LaunchpadLibrary(items: [
            LaunchItem(name: "Folder", category: .directory, target: .directory(path: "/tmp/projects"),
                       isAvailable: true, bookmarkData: Data([1, 2, 3])),
            LaunchItem(name: "App", category: .application,
                       target: .application(bundleIdentifier: "com.example.app", path: nil),
                       bookmarkData: Data([4, 5])),
            website(),
        ], selectedPages: [.directory: 2])
        let data = try backup(local).encoded()
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        for key in ["bookmarkData", "isAvailable", "selectedPages"] {
            XCTAssertFalse(json.contains("\"\(key)\""))
        }
        let decoded = try ConfigurationBackup.decode(data)
        XCTAssertTrue(decoded.library.selectedPages.isEmpty)
        XCTAssertTrue(decoded.library.items.allSatisfy { $0.bookmarkData == nil })
        XCTAssertEqual(decoded.library.items.map(\.isAvailable), [false, false, true])
    }

    func testRequiredItemFieldsCannotUseLegacyDefaults() throws {
        for field in ["id", "name", "category", "target", "pageIndex", "orderIndex"] {
            let data = try mutate(backup()) { object in
                var payload = object["payload"] as! [String: Any]
                var library = payload["library"] as! [String: Any]
                var items = library["items"] as! [[String: Any]]
                items[0].removeValue(forKey: field)
                library["items"] = items
                payload["library"] = library
                object["payload"] = payload
            }
            XCTAssertThrowsError(try ConfigurationBackup.decode(data), field)
        }
    }

    func testRequiredGroupsAndPreferencesCannotUseLegacyDefaults() throws {
        for field in ["groups", "items"] {
            let data = try mutate(backup()) { object in
                var payload = object["payload"] as! [String: Any]
                var library = payload["library"] as! [String: Any]
                library.removeValue(forKey: field)
                payload["library"] = library
                object["payload"] = payload
            }
            XCTAssertThrowsError(try ConfigurationBackup.decode(data))
        }
        for field in ["hidesAfterOpen", "windowPosition"] {
            let data = try mutate(backup()) { object in
                var payload = object["payload"] as! [String: Any]
                var preferences = payload["preferences"] as! [String: Any]
                preferences.removeValue(forKey: field)
                payload["preferences"] = preferences
                object["payload"] = payload
            }
            XCTAssertThrowsError(try ConfigurationBackup.decode(data))
        }
    }

    func testFutureVersionsWrongFormatAndSectionsAreRejected() throws {
        for (key, value) in [
            ("schemaVersion", 2 as Any), ("format", "other" as Any),
            ("includedSections", ["library"] as Any),
            ("includedSections", ["library", "library"] as Any),
            ("includedSections", ["library", "preferences", "secrets"] as Any),
        ] {
            XCTAssertThrowsError(try ConfigurationBackup.decode(mutate(backup()) { $0[key] = value }))
        }
        for section in ["library", "preferences"] {
            let data = try mutate(backup()) { object in
                var payload = object["payload"] as! [String: Any]
                var sectionObject = payload[section] as! [String: Any]
                sectionObject["version"] = 999
                payload[section] = sectionObject
                object["payload"] = payload
            }
            XCTAssertThrowsError(try ConfigurationBackup.decode(data))
        }
    }

    func testDuplicateIDsAndTargetsAreRejected() throws {
        let item = website()
        XCTAssertThrowsError(try ConfigurationBackup.validate(library: LaunchpadLibrary(items: [item, item])))
        XCTAssertThrowsError(try ConfigurationBackup.validate(library: LaunchpadLibrary(items: [item, website()])))
        let group = LaunchGroup(id: item.id, name: "Duplicate", category: .website, itemIDs: [UUID(), UUID()])
        XCTAssertThrowsError(try ConfigurationBackup.validate(library: LaunchpadLibrary(items: [item], groups: [group])))
        let data = try mutate(backup()) { object in
            var payload = object["payload"] as! [String: Any]
            var library = payload["library"] as! [String: Any]
            let items = library["items"] as! [[String: Any]]
            library["items"] = items + items
            payload["library"] = library
            object["payload"] = payload
        }
        XCTAssertThrowsError(try ConfigurationBackup.decode(data))
    }

    private func groupedLibrary() -> LaunchpadLibrary {
        let groupID = UUID()
        var first = website(url: "https://one.example")
        var second = website(url: "https://two.example")
        first.groupID = groupID
        second.groupID = groupID
        first.pageIndex = 3
        second.pageIndex = 3
        second.orderIndex = 1
        return LaunchpadLibrary(items: [first, second], groups: [
            LaunchGroup(id: groupID, name: "Sites", category: .website, pageIndex: 3,
                        orderIndex: 4, itemIDs: [first.id, second.id]),
        ])
    }

    func testValidGroupsRoundTripAndSparseRootPositionsAreAllowed() throws {
        let library = groupedLibrary()
        XCTAssertEqual(try ConfigurationBackup.decode(backup(library).encoded()).library, library)
        var sparse = LaunchpadLibrary(items: [website()])
        sparse.items[0].pageIndex = 100
        sparse.items[0].orderIndex = 50
        XCTAssertNoThrow(try ConfigurationBackup.validate(library: sparse))
    }

    func testInvalidGroupMembershipAndLayoutAreRejected() {
        let mutations: [(inout LaunchpadLibrary) -> Void] = [
            { $0.items[0].groupID = nil },
            { $0.items[0].groupID = UUID() },
            { $0.groups[0].itemIDs[0] = UUID() },
            { $0.groups[0].itemIDs[1] = $0.groups[0].itemIDs[0] },
            { $0.items[0].pageIndex = 2 },
            { $0.items[0].orderIndex = 1 },
            { $0.groups[0].category = .directory },
            { $0.groups[0].itemIDs.removeLast() },
            { $0.groups.append($0.groups[0]) },
        ]
        for mutation in mutations {
            var library = groupedLibrary()
            mutation(&library)
            XCTAssertThrowsError(try ConfigurationBackup.validate(library: library))
        }
    }

    func testDangerousTargetsAndInvalidPositionsAreRejected() {
        for url in ["javascript:alert(1)", "file:///tmp/secret", "https:///", "ftp://example.com", "relative"] {
            XCTAssertThrowsError(try backup(LaunchpadLibrary(items: [website(url: url)])).encoded())
        }
        for path in ["relative/path", "~/Documents", "/tmp/\0bad"] {
            let item = LaunchItem(name: "Directory", category: .directory, target: .directory(path: path))
            XCTAssertThrowsError(try ConfigurationBackup.validate(library: LaunchpadLibrary(items: [item])))
        }
        let missingApp = LaunchItem(name: "App", category: .application,
                                    target: .application(bundleIdentifier: "", path: nil))
        XCTAssertThrowsError(try ConfigurationBackup.validate(library: LaunchpadLibrary(items: [missingApp])))
        for value in [-1, 10_000, Int.max] {
            var library = LaunchpadLibrary(items: [website()])
            library.items[0].pageIndex = value
            XCTAssertThrowsError(try ConfigurationBackup.validate(library: library))
            library.items[0].pageIndex = 0
            library.items[0].orderIndex = value
            XCTAssertThrowsError(try ConfigurationBackup.validate(library: library))
        }
    }

    func testSizeItemCountAndNonFiniteDatesAreRejected() throws {
        XCTAssertThrowsError(try ConfigurationBackup.decode(Data(repeating: 32, count: ConfigurationBackup.maximumFileSize + 1)))
        var item = website()
        item.name = String(repeating: "x", count: ConfigurationBackup.maximumFileSize)
        XCTAssertThrowsError(try backup(LaunchpadLibrary(items: [item])).encoded())
        XCTAssertThrowsError(try ConfigurationBackup.validate(library: LaunchpadLibrary(items: Array(repeating: website(), count: 10_001))))
        for value in [Double.infinity, -Double.infinity, Double.nan] {
            let invalid = ConfigurationBackup(library: LaunchpadLibrary(),
                                              preferences: PortableAppPreferences(hidesAfterOpen: true, windowPosition: .nearPointer),
                                              appVersion: "1", exportedAt: Date(timeIntervalSince1970: value))
            XCTAssertThrowsError(try invalid.encoded())
        }
    }

    func testAtomicFileRoundTripAndOversizedFileRejection() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("config.inchspacebackup")
        let original = backup()
        try original.write(to: url)
        XCTAssertEqual(try ConfigurationBackup.read(from: url).library, original.library)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(ConfigurationBackup.maximumFileSize + 1))
        try handle.close()
        XCTAssertThrowsError(try ConfigurationBackup.read(from: url))
        XCTAssertThrowsError(try ConfigurationBackup.read(from: folder))
        let fifo = folder.appendingPathComponent("fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try ConfigurationBackup.read(from: fifo))
    }
}
