import CoreGraphics
import XCTest
@testable import inchspace

final class EnvironmentTableColumnLayoutTests: XCTestCase {
    func testNameColumnWidthClampsToConfiguredBounds() {
        XCTAssertEqual(
            EnvironmentTableColumnLayout.nameWidth(40, availableWidth: 1_200),
            EnvironmentTableColumnLayout.minimumNameWidth
        )
        XCTAssertEqual(
            EnvironmentTableColumnLayout.nameWidth(900, availableWidth: 1_200),
            EnvironmentTableColumnLayout.maximumNameWidth
        )
    }

    func testNameColumnLeavesMinimumRoomForOtherColumns() {
        let availableWidth: CGFloat = 700
        let width = EnvironmentTableColumnLayout.nameWidth(420, availableWidth: availableWidth)
        let reservedWidth = EnvironmentTableColumnLayout.horizontalPadding * 2
            + EnvironmentTableColumnLayout.intercolumnSpacing * 4
            + EnvironmentTableColumnLayout.minimumValueWidth
            + EnvironmentTableColumnLayout.sourceWidth
            + EnvironmentTableColumnLayout.statusWidth
            + EnvironmentTableColumnLayout.disclosureWidth

        XCTAssertEqual(width + reservedWidth, availableWidth)
    }
}
