import XCTest
@testable import SpaceManager

final class PlacementGeometryTests: XCTestCase {
    let visible = CGRect(x: 0, y: 30, width: 3840, height: 1590)

    func testHalves() {
        let left = PlacementGeometry.targetRect(for: .init(preset: .leftHalf), visible: visible)
        XCTAssertEqual(left, CGRect(x: 0, y: 30, width: 1920, height: 1590))
        let right = PlacementGeometry.targetRect(for: .init(preset: .rightHalf), visible: visible)
        XCTAssertEqual(right, CGRect(x: 1920, y: 30, width: 1920, height: 1590))
    }

    func testCustomPassesThroughAndNilWhenUncaptured() {
        let rect = CGRect(x: 10, y: 40, width: 800, height: 600)
        XCTAssertEqual(PlacementGeometry.targetRect(
            for: .init(preset: .custom, customRect: rect), visible: visible), rect)
        XCTAssertNil(PlacementGeometry.targetRect(
            for: .init(preset: .custom, customRect: nil), visible: visible))
    }

    func testOldEntriesDecodeWithoutNewFields() throws {
        let json = #"[{"id":"00000000-0000-0000-0000-000000000000","label":"Chrome","bundleID":"com.google.Chrome","keyEquivalent":"c"}]"#
        let apps = try JSONDecoder().decode([QuickLaunchApp].self, from: json.data(using: .utf8)!)
        XCTAssertNil(apps[0].chromeProfile)
        XCTAssertNil(apps[0].placement)
    }
}
