import XCTest
@testable import SpaceManager

final class TileMetricsTests: XCTestCase {
    func testFewTilesOnAWideScreenKeepTheDesignedSize() {
        XCTAssertEqual(TileMetrics.fitting(tiles: 5, stageWidth: 1800), .full)
    }

    func testEightTilesOnALaptopShrinkToFitWithMargin() {
        // 14" MacBook Pro visible frame: 8 full-size tiles make a 1790pt row,
        // which plus the panel's shadow padding is wider than the screen.
        let tile = TileMetrics.fitting(tiles: 8, stageWidth: 1800)
        XCTAssertLessThan(tile.scale, 1)
        XCTAssertLessThanOrEqual(tile.rowWidth(tiles: 8) + TileMetrics.stageMargin * 2, 1800)
    }

    func testScaleNeverDropsBelowTheFloor() {
        XCTAssertEqual(TileMetrics.fitting(tiles: 9, stageWidth: 800).scale, TileMetrics.minScale)
    }

    func testMenuCardFollowsScaledTiles() {
        let tile = TileMetrics(scale: 0.8)
        XCTAssertLessThan(MenuMetrics.xOffset(pos: 4, tiles: 8, tile: tile),
                          MenuMetrics.xOffset(pos: 4, tiles: 8))
    }
}
