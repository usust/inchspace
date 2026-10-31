import AppKit
import SwiftUI
import XCTest
@testable import inchspace

@MainActor
final class ArchiveLayoutTests: XCTestCase {
    func testWideBreakpointBudgetsEveryColumnAndSidebar() {
        XCTAssertEqual(ArchiveWorkbenchLayout.tableColumnMinimums.reduce(0, +), 616)
        let threshold = ArchiveWorkbenchLayout.wideMinimumWidth
        XCTAssertFalse(ArchiveWorkbenchLayout.isWide(width: 880))
        XCTAssertFalse(ArchiveWorkbenchLayout.isWide(width: threshold - 1))
        XCTAssertTrue(ArchiveWorkbenchLayout.isWide(width: threshold))
        XCTAssertGreaterThanOrEqual(threshold - 40 - 16 - 330, 616 + 80)
    }

    func testLegendKeepsOneLineAtNarrowProposals() {
        let intrinsic = NSHostingView(rootView: ArchiveBadgeLegend()).fittingSize
        XCTAssertGreaterThan(intrinsic.width, 200)
        XCTAssertLessThan(intrinsic.height, 24)
        for width: CGFloat in [80, 200, 619, 900] {
            let host = NSHostingView(rootView: ArchiveBadgeLegend().frame(width: width))
            host.frame.size.width = width
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.fittingSize.height, intrinsic.height, accuracy: 1)
        }
        // The scope bar's ViewThatFits omits this intrinsic-width legend when it cannot fit.
    }

    func testStackedBrowserHasFiniteViewport() {
        for height: CGFloat in [0, 200, 560, 800, 2000] {
            let viewport = ArchiveWorkbenchLayout.browserHeight(availableHeight: height)
            XCTAssertTrue(viewport.isFinite)
            XCTAssertGreaterThanOrEqual(viewport, 320)
            XCTAssertLessThanOrEqual(viewport, 560)
        }
    }

    func testLongSubtitleDoesNotIncreaseHeaderHeight() {
        let longSubtitle = String(repeating: "/很长的工作区路径/文件夹 · local-model-name-", count: 100)
        // Widths represent the content area with a sidebar open, hidden, and a wide window.
        for width: CGFloat in [619, 660, 900, 1180, 1500] {
            let short = headerSize(subtitle: "~/Downloads · model", width: width)
            let long = headerSize(subtitle: longSubtitle, width: width)
            XCTAssertEqual(long.width, width, accuracy: 1)
            XCTAssertEqual(long.height, short.height, accuracy: 1)
            XCTAssertLessThan(long.height, 180)
        }
    }

    func testWorkbenchStaysWithinProposedViewportWithoutBootstrapping() {
        let suite = "ArchiveLayoutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = ArchiveViewModel(defaults: defaults)
        // Deliberately host the workbench, not ArchiveView: no task, persistence, watcher or run.
        for size in [CGSize(width: 660, height: 560), CGSize(width: 940, height: 800),
                     CGSize(width: 1180, height: 800), CGSize(width: 1500, height: 900)] {
            let host = NSHostingView(rootView: ArchiveWorkbenchView(model: model)
                .frame(width: size.width, height: size.height))
            host.frame = CGRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.fittingSize.width, size.width, accuracy: 1)
            XCTAssertEqual(host.fittingSize.height, size.height, accuracy: 1)
            XCTAssertFalse(model.isReady)
            XCTAssertFalse(model.isRunning)
            XCTAssertFalse(model.isWatching)
        }
    }

    func testPopulatedTableUsesFiniteViewport() {
        let suite = "ArchiveLayoutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = ArchiveViewModel(defaults: defaults)
        let items = (0..<200).map { index in
            ArchiveBrowserItem(path: "/inert-layout-fixture/\(index).txt", name: "文件 \(index).txt",
                               isDirectory: false, size: 100, modified: nil, kind: "文本",
                               entry: nil, stats: nil, folder: "")
        }
        for width: CGFloat in [620, ArchiveWorkbenchLayout.browserMinimumWidth, 1000] {
            let host = NSHostingView(rootView: ArchiveBrowserTable(model: model, items: items, showsFolder: false)
                .frame(width: width, height: 320))
            host.frame = CGRect(x: 0, y: 0, width: width, height: 320)
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.fittingSize.width, width, accuracy: 1)
            XCTAssertEqual(host.fittingSize.height, 320, accuracy: 1)
            XCTAssertFalse(model.isRunning)
        }
    }

    func testUnlimitedSubtitleReproducesExcessiveHeight() {
        let text = String(repeating: "长路径/文件夹/模型名称/", count: 100)
        let unlimited = NSHostingView(rootView: AppFeatureTitle("自动归档", subtitle: text).frame(width: 240))
        let limited = NSHostingView(rootView: AppFeatureTitle("自动归档", subtitle: text, subtitleLineLimit: 1)
            .frame(width: 240))
        XCTAssertGreaterThan(unlimited.fittingSize.height, 560)
        XCTAssertLessThan(limited.fittingSize.height, 100)
    }

    private func headerSize(subtitle: String, width: CGFloat) -> CGSize {
        let host = NSHostingView(rootView: ArchiveWorkbenchHeader(subtitle: subtitle) { _ in
            HStack(spacing: 8) {
                Button("立即整理", systemImage: "sparkles") {}
                Button("暂停", systemImage: "pause.fill") {}
                Button("更换文件夹", systemImage: "folder") {}
                Button("重新整理全部", systemImage: "arrow.counterclockwise") {}
                Button("模型设置", systemImage: "cpu") {}
            }
            .buttonStyle(.bordered)
        }.frame(width: width))
        host.frame.size.width = width
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }
}
