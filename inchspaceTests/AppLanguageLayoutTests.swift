import AppKit
import SwiftUI
import XCTest
@testable import inchspace

@MainActor
final class AppLanguageLayoutTests: XCTestCase {
    func testWideBreakpointBudgetsTheMaximumListWidth() {
        let threshold = AppLanguageLayout.wideMinimumWidth
        XCTAssertFalse(AppLanguageLayout.isWide(width: 619))
        XCTAssertFalse(AppLanguageLayout.isWide(width: 699))
        XCTAssertFalse(AppLanguageLayout.isWide(width: threshold - 1))
        XCTAssertTrue(AppLanguageLayout.isWide(width: threshold))
        XCTAssertGreaterThanOrEqual(threshold - AppLanguageLayout.listMaximumWidth - 1,
                                    AppLanguageLayout.detailMinimumWidth)
    }

    func testCompactListLeavesSpaceForDetail() {
        for height: CGFloat in [0, 100, 300, 440, 560, 800, 2000] {
            let listHeight = AppLanguageLayout.listHeight(availableHeight: height)
            XCTAssertTrue(listHeight.isFinite)
            XCTAssertGreaterThanOrEqual(listHeight, 0)
            XCTAssertLessThanOrEqual(listHeight, 280)
            XCTAssertLessThanOrEqual(listHeight, height * 0.42)
        }
    }

    func testWorkbenchFitsNarrowAndWideViewportsWithoutScanning() {
        for populated in [false, true] {
            let model = makeModel(populated: populated)
            let host = NSHostingView(rootView: AppLanguageWorkbenchView(model: model))
            let window = makeWindow(host: host)
            defer { window.close() }

            for width: CGFloat in [619, 660, 699, AppLanguageLayout.wideMinimumWidth - 1,
                                   AppLanguageLayout.wideMinimumWidth, 956, 1280, 619] {
                window.setContentSize(NSSize(width: width, height: 560))
                layout(host)
                XCTAssertEqual(host.bounds.width, width, accuracy: 1)
                assertScrollViewsFit(host)
                XCTAssertFalse(model.isScanning)
                XCTAssertNil(model.error)
                XCTAssertEqual(model.selectedLanguage, "fr")
                XCTAssertEqual(model.savedLanguage, "en")
                XCTAssertEqual(model.selection, model.applications.first?.id)
            }
        }
    }

    func testNavigationSidebarFitsAtMinimumWindowWidth() {
        let model = makeModel(populated: true)
        let host = NSHostingView(rootView: NavigationSplitView {
            AppSidebar(selection: .constant(.appLanguage))
        } detail: {
            AppLanguageWorkbenchView(model: model)
        }
        .navigationSplitViewStyle(.balanced))
        let window = makeWindow(host: host)
        defer { window.close() }

        for width: CGFloat in [1180, 900, 1000, 900] {
            window.setContentSize(NSSize(width: width, height: 560))
            layout(host)
            XCTAssertEqual(host.bounds.width, width, accuracy: 1)
            assertScrollViewsFit(host)
        }
    }

    private func makeModel(populated: Bool) -> AppLanguageViewModel {
        let model = AppLanguageViewModel()
        if populated {
            model.applications = (0..<30).map { index in
                LanguageApplication(
                    url: URL(fileURLWithPath: "/inert-layout-fixture/\(String(repeating: "很长的目录/", count: 12))\(index).app"),
                    name: "布局测试应用 \(index) \(String(repeating: "长名称", count: 12))",
                    bundleIdentifier: "test.layout.\(String(repeating: "longidentifier", count: 8)).\(index)",
                    languages: ["en", "fr", "zh-Hans"]
                )
            }
            model.selection = model.applications.first?.id
        }
        model.selectedLanguage = "fr"
        model.savedLanguage = "en"
        return model
    }

    private func makeWindow<V: View>(host: NSHostingView<V>) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        return window
    }

    private func layout(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
    }

    private func assertScrollViewsFit(_ host: NSView, file: StaticString = #filePath, line: UInt = #line) {
        let scrollViews = descendants(of: host).compactMap { $0 as? NSScrollView }
        XCTAssertGreaterThanOrEqual(scrollViews.count, 2, file: file, line: line)
        for scrollView in scrollViews {
            let rect = scrollView.convert(scrollView.bounds, to: host)
            XCTAssertGreaterThanOrEqual(rect.minX, -1, file: file, line: line)
            XCTAssertLessThanOrEqual(rect.maxX, host.bounds.width + 1, file: file, line: line)
            XCTAssertGreaterThan(rect.height, 0, file: file, line: line)
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
