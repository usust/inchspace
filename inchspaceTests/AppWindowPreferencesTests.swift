import Carbon.HIToolbox
import XCTest
@testable import inchspace

@MainActor
final class AppWindowPreferencesTests: XCTestCase {
    func testNewPreferencesUseLauncherFriendlyDefaults() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = AppWindowPreferences(defaults: defaults)

        XCTAssertTrue(preferences.hidesAfterOpen)
        XCTAssertTrue(preferences.showsDockIcon)
        XCTAssertTrue(preferences.showsMenuBarIcon)
        XCTAssertEqual(preferences.position, .nearPointer)
        XCTAssertEqual(preferences.shortcut, .defaultShortcut)
        XCTAssertEqual(preferences.shortcut.displayName, "⌥ Space")
    }

    func testPreferencesPersistWithoutTouchingLaunchpadData() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let customShortcut = AppGlobalShortcut(
            keyCode: UInt32(kVK_ANSI_K),
            modifiers: UInt32(cmdKey | shiftKey),
            keyLabel: "K"
        )

        let first = AppWindowPreferences(defaults: defaults)
        first.setHidesAfterOpen(false)
        first.setShowsDockIcon(false)
        first.setShowsMenuBarIcon(false)
        first.setPosition(.screenCenter)
        first.setShortcut(customShortcut)

        let reloaded = AppWindowPreferences(defaults: defaults)
        XCTAssertFalse(reloaded.hidesAfterOpen)
        XCTAssertFalse(reloaded.showsDockIcon)
        XCTAssertFalse(reloaded.showsMenuBarIcon)
        XCTAssertEqual(reloaded.position, .screenCenter)
        XCTAssertEqual(reloaded.shortcut, customShortcut)
        XCTAssertEqual(reloaded.shortcut.displayName, "⇧⌘ K")
    }

    func testApplyingSyncedPreferencesKeepsDeviceSpecificSettings() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let localShortcut = AppGlobalShortcut(
            keyCode: UInt32(kVK_ANSI_K),
            modifiers: UInt32(cmdKey | shiftKey),
            keyLabel: "K"
        )
        let preferences = AppWindowPreferences(defaults: defaults)
        preferences.setShowsDockIcon(false)
        preferences.setShowsMenuBarIcon(false)
        preferences.setShortcut(localShortcut)
        let remoteDate = Date(timeIntervalSince1970: 1_786_300_000)

        preferences.applySyncedPreferences(
            SyncedAppPreferences(
                hidesAfterOpen: false,
                windowPosition: .screenCenter
            ),
            modifiedAt: remoteDate
        )

        XCTAssertFalse(preferences.hidesAfterOpen)
        XCTAssertEqual(preferences.position, .screenCenter)
        XCTAssertFalse(preferences.showsDockIcon)
        XCTAssertFalse(preferences.showsMenuBarIcon)
        XCTAssertEqual(preferences.shortcut, localShortcut)
        XCTAssertEqual(preferences.syncedModifiedAt, remoteDate)

        let reloaded = AppWindowPreferences(defaults: defaults)
        XCTAssertFalse(reloaded.hidesAfterOpen)
        XCTAssertEqual(reloaded.position, .screenCenter)
        XCTAssertFalse(reloaded.showsDockIcon)
        XCTAssertFalse(reloaded.showsMenuBarIcon)
        XCTAssertEqual(reloaded.shortcut, localShortcut)
        XCTAssertEqual(reloaded.syncedModifiedAt, remoteDate)
    }

    func testOnlyPortablePreferencesAdvanceCloudModificationDate() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AppWindowPreferences(defaults: defaults)

        preferences.setShowsDockIcon(false)
        preferences.setShowsMenuBarIcon(false)
        XCTAssertNil(preferences.syncedModifiedAt)

        preferences.setHidesAfterOpen(false)
        let firstDate = preferences.syncedModifiedAt
        XCTAssertNotNil(firstDate)

        preferences.setPosition(.screenCenter)
        XCTAssertNotNil(preferences.syncedModifiedAt)
        XCTAssertGreaterThanOrEqual(preferences.syncedModifiedAt!, firstDate!)
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "inchspace-tests-window-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
