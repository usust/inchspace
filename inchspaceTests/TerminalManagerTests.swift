import XCTest
@testable import inchspace

@MainActor
final class TerminalManagerTests: XCTestCase {
    func testLocalSessionsKeepIndependentIdentityAndSelection() {
        let (preferences, suiteName) = makePreferences()
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let manager = TerminalManager(preferences: preferences)

        let first = manager.openLocalSession(directory: "/tmp")
        let second = manager.openLocalSession(directory: "/")

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(manager.sessions.map(\.id), [first.id, second.id])
        XCTAssertEqual(manager.selectedSessionID, second.id)

        manager.select(first.id)
        XCTAssertEqual(manager.selectedSessionID, first.id)
        XCTAssertFalse(first.isRunning)
        XCTAssertFalse(second.isRunning)
    }

    func testSplitCreatesPaneInsideTheSelectedSessionWithoutAddingTab() {
        let (preferences, _) = makePreferences()
        let manager = TerminalManager(preferences: preferences)
        let primary = manager.openLocalSession(directory: "/tmp")

        manager.split(.horizontal)

        XCTAssertEqual(manager.selectedSessionID, primary.id)
        XCTAssertEqual(manager.sessions.count, 1)
        XCTAssertEqual(primary.panes.count, 2)
        XCTAssertNotEqual(primary.panes[0].id, primary.panes[1].id)
        XCTAssertEqual(
            primary.paneLayout,
            .split(.horizontal, .pane(primary.panes[0].id), .pane(primary.panes[1].id))
        )

        let secondaryID = primary.activePaneID
        XCTAssertTrue(primary.closePane(secondaryID))
        XCTAssertEqual(primary.panes.count, 1)
        XCTAssertEqual(manager.sessions.count, 1)
    }

    func testNestedSplitsAndPaneCloseKeepTheRemainingLayoutValid() {
        let (preferences, _) = makePreferences()
        let manager = TerminalManager(preferences: preferences)
        let session = manager.openLocalSession(directory: "/tmp")
        let firstID = session.activePaneID

        manager.split(.vertical)
        let secondID = session.activePaneID
        manager.split(.horizontal)
        let thirdID = session.activePaneID

        XCTAssertEqual(manager.sessions.count, 1)
        XCTAssertEqual(session.panes.count, 3)
        XCTAssertTrue(session.paneLayout.contains(firstID))
        XCTAssertTrue(session.paneLayout.contains(secondID))
        XCTAssertTrue(session.paneLayout.contains(thirdID))

        XCTAssertTrue(session.closePane(secondID))
        XCTAssertEqual(session.panes.count, 2)
        XCTAssertTrue(session.paneLayout.contains(firstID))
        XCTAssertFalse(session.paneLayout.contains(secondID))
        XCTAssertTrue(session.paneLayout.contains(thirdID))
        XCTAssertEqual(manager.sessions.count, 1)
    }

    func testServerConnectUsesUnifiedTerminalHandler() {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("inchspace-terminal-route-\(UUID().uuidString).json")
        let serverManager = ServerManager(persistence: ServerPersistence(fileURL: fileURL))
        let credential = SSHCredential(serverID: UUID(), authentication: .agent)
        let server = Server(name: "Remote", host: "10.0.0.8", user: "deploy", credentialID: credential.id)
        var routedServerID: UUID?
        serverManager.terminalConnectionHandler = { routedServerID = $0.id }

        serverManager.connect(to: server)

        XCTAssertEqual(routedServerID, server.id)
        try? FileManager.default.removeItem(at: fileURL)
    }

    func testLocalPTYProcessesUnicodeANSIAndResize() async throws {
        let (preferences, _) = makePreferences()
        let manager = TerminalManager(preferences: preferences)
        let session = manager.openLocalSession(directory: "/tmp")
        session.startIfNeeded()
        defer { session.terminate() }
        XCTAssertTrue(session.isRunning)

        session.terminalView.resize(cols: 100, rows: 30)
        XCTAssertEqual(session.terminalView.getTerminal().cols, 100)
        XCTAssertEqual(session.terminalView.getTerminal().rows, 30)

        try await Task.sleep(for: .milliseconds(300))
        let command = "printf '\\033[31mINCH%b\\033[0m\\n' 'SPACE_PTY_OK_\\u4f60\\u597d'; printf '8J+YgA==' | /usr/bin/base64 -D; printf '\\n'\r"
        let bytes = Array(command.utf8)
        session.terminalView.send(source: session.terminalView, data: bytes[...])
        var lastBuffer = ""
        for _ in 0..<40 {
            let data = session.terminalView.getTerminal().getBufferAsData()
            lastBuffer = String(decoding: data, as: UTF8.self)
            if lastBuffer.contains("INCHSPACE_PTY_OK_"), session.terminalView.findNext("😀") { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(lastBuffer.contains("INCHSPACE_PTY_OK_"), "PTY 命令输出未进入 Cell Grid")
        XCTAssertTrue(lastBuffer.contains("你"), "缺少中文宽字符：\(lastBuffer.prefix(500))")
        XCTAssertTrue(lastBuffer.contains("好"), "缺少中文宽字符：\(lastBuffer.prefix(500))")
        XCTAssertTrue(session.terminalView.findNext("😀"), "SwiftTerm Grapheme Store 缺少 Emoji")
    }

    func testTerminalContainerInsetsDefineTheRealGridArea() {
        let (preferences, _) = makePreferences()
        let manager = TerminalManager(preferences: preferences)
        let session = manager.openLocalSession(directory: "/tmp")
        let container = TerminalContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))

        container.attach(session.terminalView)
        container.layoutSubtreeIfNeeded()

        XCTAssertEqual(session.terminalView.frame, NSRect(x: 18, y: 14, width: 764, height: 472))
        let initialColumns = session.terminalView.getTerminal().cols
        let initialRows = session.terminalView.getTerminal().rows

        container.frame.size = NSSize(width: 600, height: 360)
        container.needsLayout = true
        container.layoutSubtreeIfNeeded()

        XCTAssertEqual(session.terminalView.frame, NSRect(x: 18, y: 14, width: 564, height: 332))
        XCTAssertLessThan(session.terminalView.getTerminal().cols, initialColumns)
        XCTAssertLessThan(session.terminalView.getTerminal().rows, initialRows)
    }

    func testMovingPrimaryTerminalToSplitContainerSurvivesOldContainerTeardown() {
        let (preferences, _) = makePreferences()
        let manager = TerminalManager(preferences: preferences)
        let primary = manager.openLocalSession(directory: "/tmp")
        let originalContainer = TerminalContainerView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 500)
        )
        let leftSplitContainer = TerminalContainerView(
            frame: NSRect(x: 0, y: 0, width: 450, height: 500)
        )

        originalContainer.attach(primary.terminalView)
        leftSplitContainer.attach(primary.terminalView)
        originalContainer.detachTerminal()

        XCTAssertTrue(primary.terminalView.superview === leftSplitContainer)
        XCTAssertEqual(
            primary.terminalView.frame,
            NSRect(x: 18, y: 14, width: 414, height: 472)
        )

        originalContainer.frame.size = NSSize(width: 300, height: 200)
        originalContainer.needsLayout = true
        originalContainer.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            primary.terminalView.frame,
            NSRect(x: 18, y: 14, width: 414, height: 472),
            "旧容器不应再移除或调整已经迁移到左侧分屏的当前终端"
        )
    }

    func testRepeatedSplitLayoutChangesCannotLetStaleContainersStealTerminals() {
        let (preferences, _) = makePreferences()
        let manager = TerminalManager(preferences: preferences)
        let primary = manager.openLocalSession(directory: "/tmp")
        manager.split(.vertical)
        let secondary = primary.activePane
        let firstPane = primary.panes[0]

        var previousPrimary = TerminalContainerView(
            frame: NSRect(x: 0, y: 0, width: 450, height: 500)
        )
        var previousSecondary = TerminalContainerView(
            frame: NSRect(x: 450, y: 0, width: 450, height: 500)
        )
        previousPrimary.attach(firstPane.terminalView)
        previousSecondary.attach(secondary.terminalView)

        for iteration in 0..<30 {
            let isVertical = iteration.isMultiple(of: 2)
            let paneSize = isVertical
                ? NSSize(width: 450, height: 500)
                : NSSize(width: 900, height: 250)
            let currentPrimary = TerminalContainerView(
                frame: NSRect(origin: .zero, size: paneSize)
            )
            let currentSecondary = TerminalContainerView(
                frame: NSRect(origin: .zero, size: paneSize)
            )

            currentPrimary.attach(firstPane.terminalView)
            currentSecondary.attach(secondary.terminalView)

            // Simulate late update/dismantle callbacks from the hierarchy that
            // SwiftUI just replaced while changing split orientation.
            previousPrimary.attach(firstPane.terminalView)
            previousSecondary.attach(secondary.terminalView)
            previousPrimary.detachTerminal()
            previousSecondary.detachTerminal()

            XCTAssertTrue(firstPane.terminalView.superview === currentPrimary)
            XCTAssertTrue(secondary.terminalView.superview === currentSecondary)
            XCTAssertGreaterThan(firstPane.terminalView.frame.width, 0)
            XCTAssertGreaterThan(secondary.terminalView.frame.height, 0)

            previousPrimary = currentPrimary
            previousSecondary = currentSecondary
        }
    }

    func testLightDarkAndSystemThemesResolveDistinctSurfaces() {
        let (preferences, _) = makePreferences()
        let manager = TerminalManager(preferences: preferences)
        let session = manager.openLocalSession(directory: "/tmp")

        preferences.theme = .light
        session.applyAppearance()
        let lightBackground = session.terminalView.nativeBackgroundColor

        preferences.theme = .dark
        session.applyAppearance()
        let darkBackground = session.terminalView.nativeBackgroundColor

        XCTAssertNotEqual(lightBackground, darkBackground)

        preferences.theme = .system
        session.applyAppearance(systemIsDark: false)
        let systemLightBackground = session.terminalView.nativeBackgroundColor
        session.applyAppearance(systemIsDark: true)
        let systemDarkBackground = session.terminalView.nativeBackgroundColor

        XCTAssertEqual(systemLightBackground, lightBackground)
        XCTAssertEqual(systemDarkBackground, darkBackground)
    }

    private func makePreferences() -> (TerminalPreferences, String) {
        let suiteName = "inchspace-tests-terminal-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (TerminalPreferences(defaults: defaults), suiteName)
    }
}
