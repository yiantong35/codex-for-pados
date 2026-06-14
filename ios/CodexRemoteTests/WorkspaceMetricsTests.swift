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

    // 右栏自绘拖动：把手在右栏左缘，向左拖（dragX<0）增宽。
    func testResizedRightWidthDragLeftIncreasesWidth() {
        XCTAssertEqual(WorkspaceMetrics.resizedRightWidth(current: 320, dragX: -50), 370)
    }
    func testResizedRightWidthDragRightDecreasesWidth() {
        XCTAssertEqual(WorkspaceMetrics.resizedRightWidth(current: 320, dragX: 50), 270)
    }
    func testResizedRightWidthClampsToMax() {
        XCTAssertEqual(WorkspaceMetrics.resizedRightWidth(current: 320, dragX: -900),
                       WorkspaceMetrics.rightPanelMaxWidth)
    }
    func testResizedRightWidthClampsToMin() {
        XCTAssertEqual(WorkspaceMetrics.resizedRightWidth(current: 320, dragX: 900),
                       WorkspaceMetrics.rightPanelMinWidth)
    }
}
