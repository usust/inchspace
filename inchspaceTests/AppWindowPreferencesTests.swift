import AppKit
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

    func testApplyingPortablePreferencesKeepsDeviceSpecificSettings() {
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

        preferences.applyPortablePreferences(
            PortableAppPreferences(
                hidesAfterOpen: false,
                windowPosition: .screenCenter
            )
        )

        XCTAssertFalse(preferences.hidesAfterOpen)
        XCTAssertEqual(preferences.position, .screenCenter)
        XCTAssertFalse(preferences.showsDockIcon)
        XCTAssertFalse(preferences.showsMenuBarIcon)
        XCTAssertEqual(preferences.shortcut, localShortcut)

        let reloaded = AppWindowPreferences(defaults: defaults)
        XCTAssertFalse(reloaded.hidesAfterOpen)
        XCTAssertEqual(reloaded.position, .screenCenter)
        XCTAssertFalse(reloaded.showsDockIcon)
        XCTAssertFalse(reloaded.showsMenuBarIcon)
        XCTAssertEqual(reloaded.shortcut, localShortcut)
    }

    func testLegacySyncSettingsAreNotUsedOrUpdated() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "iCloudDriveSyncEnabled")
        let oldDate = Date(timeIntervalSince1970: 100)
        defaults.set(oldDate, forKey: "window.syncedPreferencesModifiedAt")
        let preferences = AppWindowPreferences(defaults: defaults)
        preferences.setHidesAfterOpen(false)
        preferences.setPosition(.screenCenter)
        XCTAssertEqual(defaults.object(forKey: "window.syncedPreferencesModifiedAt") as? Date, oldDate)
        XCTAssertEqual(preferences.portablePreferences.windowPosition, .screenCenter)
    }

    func testMainWindowBridgeReportsEachWindowOnlyWhenAttachmentChanges() {
        let firstWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let secondWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        var reportedWindows: [NSWindow] = []
        let bridge = MainWindowRegistrationView { reportedWindows.append($0) }

        firstWindow.contentView?.addSubview(bridge)
        bridge.viewDidMoveToWindow()
        XCTAssertEqual(reportedWindows.count, 1)
        XCTAssertTrue(reportedWindows.first === firstWindow)

        bridge.removeFromSuperview()
        firstWindow.contentView?.addSubview(bridge)
        XCTAssertEqual(reportedWindows.count, 1)

        bridge.removeFromSuperview()
        secondWindow.contentView?.addSubview(bridge)
        XCTAssertEqual(reportedWindows.count, 2)
        XCTAssertTrue(reportedWindows.last === secondWindow)
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "inchspace-tests-window-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
