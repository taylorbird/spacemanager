import XCTest
@testable import SpaceManager

final class MenuMetricsTests: XCTestCase {
    func testSubmenuHeightAddsOneProfileRowPerProfile() {
        // label 18 + insets 14
        XCTAssertEqual(MenuMetrics.submenuHeight(profiles: 0), 32)
        XCTAssertEqual(MenuMetrics.submenuHeight(profiles: 3), 32 + 3 * MenuMetrics.profileRowHeight)
    }

    func testAppCellTopStacksRowsDividerAndLabel() {
        // inset 7 + rename 40 + move row 40 + divider block 11 + label 18 + 2 cells 144
        XCTAssertEqual(MenuMetrics.appCellTop(pos: 2, extraRows: 1), 260)
    }

    func testSubmenuSitsRightOfMenuCardWhenItFits() {
        let menuX = MenuMetrics.xOffset(pos: 0, tiles: 3)
        XCTAssertEqual(MenuMetrics.submenuXOffset(pos: 0, tiles: 3, stageWidth: 1920),
                       menuX + MenuMetrics.width + MenuMetrics.submenuGap)
    }

    func testSubmenuFlipsLeftNearScreenEdge() {
        // 8 tiles make a row wider than half of this stage; the last tile's
        // card is clamped to the row's right edge, so a right-hand submenu
        // would overflow the stage.
        let tiles = 8
        let stage = MenuMetrics.rowWidth(tiles: tiles) + 100
        let menuX = MenuMetrics.xOffset(pos: tiles - 1, tiles: tiles)
        XCTAssertEqual(MenuMetrics.submenuXOffset(pos: tiles - 1, tiles: tiles, stageWidth: stage),
                       menuX - MenuMetrics.submenuGap - MenuMetrics.submenuWidth)
    }
}
