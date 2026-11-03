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

    func testSuccessfulExternalOpenUsesNativeMiniaturization() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = AppVisibilityController(preferences: AppWindowPreferences(defaults: defaults))
        let window = MiniaturizationWindow()
        controller.registerMainWindow(window)

        controller.minimizeAfterSuccessfulOpen(.init(runningApplication: nil, bundleIdentifier: "com.apple.finder"))

        XCTAssertEqual(window.miniaturizeCount, 1)
        XCTAssertEqual(window.tabbingMode, .disallowed)
    }

    func testDisabledPreferenceAndSelfOpenLeaveWindowAlone() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AppWindowPreferences(defaults: defaults)
        let controller = AppVisibilityController(preferences: preferences)
        let window = MiniaturizationWindow()
        controller.registerMainWindow(window)

        preferences.setHidesAfterOpen(false)
        controller.minimizeAfterSuccessfulOpen(.init(runningApplication: nil, bundleIdentifier: "com.apple.finder"))
        preferences.setHidesAfterOpen(true)
        controller.minimizeAfterSuccessfulOpen(.init(runningApplication: .current, bundleIdentifier: Bundle.main.bundleIdentifier))

        XCTAssertEqual(window.miniaturizeCount, 0)
    }

    func testInstancePriorityUsesLaunchDateThenProcessIdentifier() {
        let earlier = Date(timeIntervalSince1970: 100)
        let later = Date(timeIntervalSince1970: 200)
        XCTAssertTrue(AppInstancePolicy.precedes(launchDate: earlier, processIdentifier: 200,
                                               currentLaunchDate: later, currentProcessIdentifier: 100))
        XCTAssertFalse(AppInstancePolicy.precedes(launchDate: later, processIdentifier: 100,
                                                currentLaunchDate: earlier, currentProcessIdentifier: 200))
        XCTAssertTrue(AppInstancePolicy.precedes(launchDate: earlier, processIdentifier: 100,
                                               currentLaunchDate: earlier, currentProcessIdentifier: 200))
        XCTAssertFalse(AppInstancePolicy.precedes(launchDate: nil, processIdentifier: 200,
                                                currentLaunchDate: nil, currentProcessIdentifier: 100))
        XCTAssertFalse(AppInstancePolicy.precedes(launchDate: earlier, processIdentifier: 100,
                                                currentLaunchDate: earlier, currentProcessIdentifier: 100))
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "inchspace-tests-window-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}

@MainActor
private final class MiniaturizationWindow: NSWindow {
    private(set) var miniaturizeCount = 0

    override var isVisible: Bool { true }
    override var isMiniaturized: Bool { miniaturizeCount > 0 }

    override func miniaturize(_ sender: Any?) {
        miniaturizeCount += 1
    }
}
