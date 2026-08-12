import XCTest
@testable import ThreeColSpike

final class ThreeColumnSpikeTests: XCTestCase {
    @MainActor
    func testInitialWidthsFitA768PointContainer() {
        let result = ThreeColumnSpikeView.constrainedWidths(total: 768, left: 280, right: 320)
        XCTAssertGreaterThanOrEqual(result.middle, ThreeColumnSpikeView.minimumMiddleWidth)
        XCTAssertEqual(
            result.left + result.middle + result.right + ThreeColumnSpikeView.dividerHitWidth * 2,
            768,
            accuracy: 0.01
        )
    }

    @MainActor
    func testVeryNarrowContainerNeverOverflows() {
        let result = ThreeColumnSpikeView.constrainedWidths(total: 360, left: 280, right: 320)
        XCTAssertEqual(result.left, 0)
        XCTAssertEqual(result.middle, 360)
        XCTAssertEqual(result.right, 0)
    }
}
