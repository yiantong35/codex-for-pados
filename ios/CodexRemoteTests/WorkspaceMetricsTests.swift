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
    func testColumnResizeHandleCenterYUsesSharedContainerMidline() {
        let containerHeight: CGFloat = 720

        XCTAssertEqual(WorkspaceMetrics.columnResizeHandleCenterY(in: containerHeight),
                       containerHeight / 2)
    }
    func testColumnResizeHandleCenterYPinsToInitialFullHeight() {
        let fullHeight: CGFloat = 920
        let reducedHeight: CGFloat = 700
        let pinnedCenterY = WorkspaceMetrics.columnResizeHandleCenterY(in: fullHeight)

        XCTAssertEqual(WorkspaceMetrics.columnResizeHandleCenterY(in: reducedHeight,
                                                                  pinnedCenterY: pinnedCenterY),
                       pinnedCenterY)
    }
    func testColumnResizeHandleCentersStraddleDividersSymmetrically() {
        let leftDividerX: CGFloat = 300
        let containerWidth: CGFloat = 1_024
        let rightPanelWidth: CGFloat = 320
        let rightDividerX = containerWidth - rightPanelWidth
        let edgeDistance = WorkspaceMetrics.columnResizeHandleEdgePadding
            + WorkspaceMetrics.columnResizeHandleInactiveWidth / 2

        XCTAssertEqual(WorkspaceMetrics.leftColumnResizeHandleCenterX(dividerX: leftDividerX),
                       leftDividerX - edgeDistance)
        XCTAssertEqual(WorkspaceMetrics.rightColumnResizeHandleCenterX(dividerX: rightDividerX),
                       rightDividerX + edgeDistance)
    }
    func testResizeHandlesShareSameVisualEdgePadding() {
        XCTAssertEqual(WorkspaceMetrics.columnResizeHandleEdgePadding,
                       WorkspaceMetrics.resizeHandleEdgePadding)
        XCTAssertEqual(WorkspaceMetrics.bottomResizeHandleTopPadding,
                       WorkspaceMetrics.resizeHandleEdgePadding)
    }
}
