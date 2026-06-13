import XCTest
import CoreGraphics
@testable import CodexRemote

final class WorkspaceMetricsTests: XCTestCase {
    func testClampBelowMinReturnsMin() {
        XCTAssertEqual(WorkspaceMetrics.clamp(50, min: 150, max: 400), 150)
    }
    func testClampAboveMaxReturnsMax() {
        XCTAssertEqual(WorkspaceMetrics.clamp(999, min: 150, max: 400), 400)
    }
    func testClampWithinRangeUnchanged() {
        XCTAssertEqual(WorkspaceMetrics.clamp(220, min: 150, max: 400), 220)
    }
    func testBottomPanelMinHeightConstantPositive() {
        XCTAssertGreaterThan(WorkspaceMetrics.bottomPanelMinHeight, 0)
    }
    func testRightPanelMinWidthConstantPositive() {
        XCTAssertGreaterThan(WorkspaceMetrics.rightPanelMinWidth, 0)
    }
}
