import AppKit
import SwiftUI
import XCTest
@testable import inchspace

@MainActor
final class AppNavigationLayoutTests: XCTestCase {
    func testOversizedDetailDoesNotMoveSidebarWhenWindowShrinks() {
        let host = NSHostingView(rootView: AppNavigationShell(selection: .constant(.pythonEnvironments)) {
            HStack {
                Text("Oversized detail")
                Spacer()
            }
            .frame(minWidth: 1600, minHeight: 900)
        })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 800),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }

        var initialSidebar: NSRect?
        var initialDocumentX: CGFloat?
        for width: CGFloat in [1180, 900, 1500, 1000, 900] {
            window.setContentSize(NSSize(width: width, height: 800))
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.bounds.width, width, accuracy: 1)
            guard let sidebar = descendants(of: host).compactMap({ $0 as? NSScrollView }).first,
                  let document = sidebar.documentView else {
                XCTFail("Sidebar list must be present")
                return
            }
            let frame = sidebar.convert(sidebar.bounds, to: host)
            let documentFrame = document.convert(document.bounds, to: host)
            XCTAssertGreaterThanOrEqual(frame.minX, -1)
            XCTAssertGreaterThanOrEqual(documentFrame.minX, -1)
            if let initialSidebar, let initialDocumentX {
                XCTAssertEqual(frame.minX, initialSidebar.minX, accuracy: 1)
                XCTAssertEqual(frame.width, initialSidebar.width, accuracy: 1)
                XCTAssertEqual(documentFrame.minX, initialDocumentX, accuracy: 1)
            } else {
                initialSidebar = frame
                initialDocumentX = documentFrame.minX
            }
        }
        window.setContentSize(NSSize(width: 1180, height: 800))
        host.layoutSubtreeIfNeeded()
        guard let split = descendants(of: host).compactMap({ $0 as? NSSplitView }).first,
              let sidebar = descendants(of: host).compactMap({ $0 as? NSScrollView }).first else {
            XCTFail("Navigation split view must be present")
            return
        }
        split.setPosition(205, ofDividerAt: 0)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let narrowWidth = sidebar.bounds.width
        split.setPosition(270, ofDividerAt: 0)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertGreaterThan(sidebar.bounds.width, narrowWidth + 30)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
