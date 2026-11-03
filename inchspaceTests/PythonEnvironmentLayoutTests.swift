import AppKit
import SwiftUI
import XCTest
@testable import inchspace

@MainActor
final class PythonEnvironmentLayoutTests: XCTestCase {
    func testListKeepsPreferredWidthInNarrowWindows() {
        for width: CGFloat in [619, 660, 699, 900, 1180] {
            XCTAssertEqual(PythonEnvironmentLayout.listWidth(preferred: 230, availableWidth: width), 230)
        }
    }

    func testDraggingListReservesDetailSpace() {
        for width: CGFloat in [619, 660, 699, 900, 1180] {
            for preferred: CGFloat in [100, 190, 230, 320, 500] {
                let listWidth = PythonEnvironmentLayout.listWidth(preferred: preferred, availableWidth: width)
                XCTAssertGreaterThanOrEqual(listWidth, 190)
                XCTAssertLessThanOrEqual(listWidth, 320)
                XCTAssertGreaterThanOrEqual(width - listWidth - 1, PythonEnvironmentLayout.detailMinimumWidth)
            }
        }
    }

    func testHeaderFitsWithAndWithoutDiscoveryProgress() {
        for discovering in [false, true] {
            for width: CGFloat in [320, 619, 660, 699, 900, 1180] {
                let host = NSHostingView(rootView: PythonEnvironmentHeader(
                    discovering: discovering, onDiscover: {}, onAdd: {}, onCreate: {}
                ).frame(width: width))
                host.frame.size.width = width
                host.layoutSubtreeIfNeeded()
                XCTAssertEqual(host.fittingSize.width, width, accuracy: 1)
                XCTAssertLessThan(host.fittingSize.height, 260)
            }
        }
    }

    func testColumnsAndSidebarRemainInsideResizedWindow() {
        let host = NSHostingView(rootView: AppNavigationShell(selection: .constant(.pythonEnvironments)) {
            GeometryReader { page in
                VStack(spacing: 0) {
                    PythonEnvironmentHeader(discovering: true, onDiscover: {}, onAdd: {}, onCreate: {})
                    PythonEnvironmentColumns {
                        List(0..<30, id: \.self) { index in
                            Text("Python 环境 \(index)")
                        }
                    } detail: {
                        PythonEnvironmentDetailView(
                            environment: PythonEnvironment(name: "Py12", path: "/inert-layout-fixture/" + String(repeating: "long-directory/", count: 20) + ".venv",
                                                           workingDirectory: "/inert-layout-fixture/project"),
                            opening: false, onOpen: { _ in }, onCopy: {}, onEdit: {},
                            onPackages: {}, onScript: {}, onRemove: {}
                        )
                    }
                }
                .frame(width: page.size.width, height: page.size.height)
            }
        })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 560),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        for width: CGFloat in [1180, 900, 1000, 1500, 900] {
            window.setContentSize(NSSize(width: width, height: 560))
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.bounds.width, width, accuracy: 1)
            let scrollViews = descendants(of: host).compactMap { $0 as? NSScrollView }
                .filter { !$0.isHiddenOrHasHiddenAncestor }
            XCTAssertGreaterThanOrEqual(scrollViews.count, 3)
            for scrollView in scrollViews {
                let rect = scrollView.convert(scrollView.bounds, to: host)
                XCTAssertGreaterThanOrEqual(rect.minX, -1)
                XCTAssertLessThanOrEqual(rect.maxX, width + 1)
                XCTAssertGreaterThan(rect.height, 0)
                if let document = scrollView.documentView {
                    XCTAssertLessThanOrEqual(document.bounds.width, scrollView.contentView.bounds.width + 1)
                }
            }
            if let sidebar = scrollViews.first(where: {
                $0.contentInsets.left == 0 && $0.bounds.width <= 280
            }), let browser = scrollViews.first(where: { $0.contentInsets.left > 0 }) {
                let sidebarFrame = sidebar.convert(sidebar.bounds, to: host)
                let browserFrame = browser.convert(browser.bounds, to: host)
                // macOS extends scroll backgrounds under the sidebar, but insets the visible content.
                let contentLeft = browserFrame.minX + browser.contentInsets.left
                let contentWidth = browserFrame.width - browser.contentInsets.left - browser.contentInsets.right
                XCTAssertEqual(contentLeft, sidebarFrame.maxX, accuracy: 1)
                XCTAssertGreaterThanOrEqual(contentWidth, 190)
                XCTAssertEqual(contentWidth, 230, accuracy: 1)
                guard let detail = scrollViews.first(where: {
                    $0.convert($0.bounds, to: host).minX >= browserFrame.maxX
                }) else {
                    XCTFail("Detail must remain to the right of the environment list")
                    return
                }
                let detailFrame = detail.convert(detail.bounds, to: host)
                XCTAssertEqual(detailFrame.minY, browserFrame.minY, accuracy: 1)
                XCTAssertEqual(detailFrame.height, browserFrame.height, accuracy: 1)
            } else {
                XCTFail("Both sidebar and environment list must remain visible")
            }
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
