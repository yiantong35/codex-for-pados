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
    func testBottomResizeHandleAndAccessibilityAdjustment() {
        XCTAssertGreaterThanOrEqual(WorkspaceMetrics.bottomResizeHandleTrackHeight, 44)
        XCTAssertEqual(WorkspaceMetrics.adjustedBottomHeight(220, increment: true), 260)
        XCTAssertEqual(
            WorkspaceMetrics.adjustedBottomHeight(WorkspaceMetrics.bottomPanelMinHeight, increment: false),
            WorkspaceMetrics.bottomPanelMinHeight
        )
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

    // MARK: - custom-resizable-columns 列宽纯函数（D4）

    func testMaxColumnWidthIsTwoThirdsOfTotal() {
        XCTAssertEqual(WorkspaceMetrics.maxColumnWidth(total: 1_200), 800, accuracy: 0.001)
    }

    func testClampColumnWidthCapsAtTwoThirds() {
        // 另一栏很窄时（byCenter ≥ 2/3），2/3 上界成为约束：proposed 1000 应被夹到 1200*2/3=800。
        // 注：other 必须窄到 byCenter=1200-other-28-320 ≥ 800（即 other ≤ 52），2/3 才真正 binding；
        // 否则中栏保护先生效。故此处用 other=40（byCenter=812），确保 2/3 是唯一约束。
        let w = WorkspaceMetrics.clampColumnWidth(
            1_000, total: 1_200, otherColumnWidth: 40,
            columnMin: WorkspaceMetrics.leftColumnMinWidth)
        XCTAssertEqual(w, 800, accuracy: 0.001)
    }

    func testClampColumnWidthProtectsCenterMinWidth() {
        // 另一栏已占 600、中栏最小 320、两分隔线 28：left 上界 = 1200-600-28-320=252，
        // 该值 < 2/3(800)，故中栏保护成为约束，proposed 1000 被夹到 252。
        let total: CGFloat = 1_200
        let other: CGFloat = 600
        let expected = total - other
            - WorkspaceMetrics.resizableDividerHitWidth * 2
            - WorkspaceMetrics.centerColumnMinWidth
        let w = WorkspaceMetrics.clampColumnWidth(
            1_000, total: total, otherColumnWidth: other,
            columnMin: WorkspaceMetrics.leftColumnMinWidth)
        XCTAssertEqual(w, expected, accuracy: 0.001)
    }

    func testClampColumnWidthFloorsAtColumnMin() {
        let w = WorkspaceMetrics.clampColumnWidth(
            10, total: 1_200, otherColumnWidth: 300,
            columnMin: WorkspaceMetrics.leftColumnMinWidth)
        XCTAssertEqual(w, WorkspaceMetrics.leftColumnMinWidth, accuracy: 0.001)
    }

    func testClampColumnWidthNeverBelowMinEvenWhenNoRoom() {
        // 极端：另一栏几乎占满，上界算出来 < columnMin，也不得返回低于 columnMin。
        let w = WorkspaceMetrics.clampColumnWidth(
            500, total: 700, otherColumnWidth: 650,
            columnMin: WorkspaceMetrics.leftColumnMinWidth)
        XCTAssertEqual(w, WorkspaceMetrics.leftColumnMinWidth, accuracy: 0.001)
    }

    func testClampColumnWidthDecoupledFromOtherColumn() {
        // 左右解耦：同一 proposed、同一 total，仅改 otherColumnWidth，返回值只随「本栏可用余量」变化，
        // 不会去修改另一栏——纯函数只返回本栏结果。
        let a = WorkspaceMetrics.clampColumnWidth(
            9_999, total: 1_400, otherColumnWidth: 300,
            columnMin: WorkspaceMetrics.rightColumnMinWidth)
        let b = WorkspaceMetrics.clampColumnWidth(
            9_999, total: 1_400, otherColumnWidth: 500,
            columnMin: WorkspaceMetrics.rightColumnMinWidth)
        // 另一栏更宽 → 本栏上界更小。
        XCTAssertGreaterThan(a, b)
    }

    func testCenterColumnWidthFloorsAtMin() {
        // 左右加起来几乎占满，中栏被夹到最小宽而非负数。
        let c = WorkspaceMetrics.centerColumnWidth(total: 1_000, left: 500, right: 490)
        XCTAssertEqual(c, WorkspaceMetrics.centerColumnMinWidth, accuracy: 0.001)
    }

    func testCenterColumnWidthNormalCase() {
        let c = WorkspaceMetrics.centerColumnWidth(total: 1_200, left: 300, right: 320)
        XCTAssertEqual(c, 1_200 - 300 - 320 - WorkspaceMetrics.resizableDividerHitWidth * 2,
                       accuracy: 0.001)
    }

    func testCenterColumnWidthWithSingleDividerReclaimsGap() {
        // 单栏隐藏：只有 1 条分隔线时，中栏应比默认（2 条）多 resizableDividerHitWidth。
        let two = WorkspaceMetrics.centerColumnWidth(total: 1_200, left: 300, right: 0, dividerCount: 2)
        let one = WorkspaceMetrics.centerColumnWidth(total: 1_200, left: 300, right: 0, dividerCount: 1)
        XCTAssertEqual(one - two, WorkspaceMetrics.resizableDividerHitWidth, accuracy: 0.001)
    }

    func testClampColumnWidthDividerCountWidensUpperBound() {
        // 分隔线更少 → 中栏保护上界更宽松 → 允许的列宽上界更大（当中栏保护是绑定约束时）。
        let two = WorkspaceMetrics.clampColumnWidth(
            9_999, total: 1_200, otherColumnWidth: 600,
            columnMin: WorkspaceMetrics.leftColumnMinWidth, dividerCount: 2)
        let one = WorkspaceMetrics.clampColumnWidth(
            9_999, total: 1_200, otherColumnWidth: 600,
            columnMin: WorkspaceMetrics.leftColumnMinWidth, dividerCount: 1)
        XCTAssertEqual(one - two, WorkspaceMetrics.resizableDividerHitWidth, accuracy: 0.001)
    }

    // MARK: - D4 窄窗三栏降级

    func testThreeColumnMinTotalWidthMatchesConstituents() {
        let expected = WorkspaceMetrics.leftColumnMinWidth
            + WorkspaceMetrics.centerColumnMinWidth
            + WorkspaceMetrics.rightColumnMinWidth
            + WorkspaceMetrics.resizableDividerHitWidth * 2
        XCTAssertEqual(WorkspaceMetrics.threeColumnMinTotalWidth, expected)
        XCTAssertEqual(WorkspaceMetrics.threeColumnMinTotalWidth, 668)
    }

    /// 宽度充足：三栏全开意图被完整保留。
    func testWidePlanKeepsBothSidebars() {
        let plan = WorkspaceMetrics.columnVisibilityPlan(total: 1024, wantLeft: true, wantRight: true)
        XCTAssertTrue(plan.showLeft); XCTAssertTrue(plan.showRight)
    }

    /// 低于三栏最低宽：先收右栏，且被显示栏最小宽之和不溢出容器。
    func testNarrowPlanCollapsesRightFirst() {
        // 容器只够 左+中+1分隔线（160+280+14=454），放不下右栏。
        let plan = WorkspaceMetrics.columnVisibilityPlan(total: 500, wantLeft: true, wantRight: true)
        XCTAssertTrue(plan.showLeft, "应保留左栏")
        XCTAssertFalse(plan.showRight, "空间不足应先收右栏")
        let sum = WorkspaceMetrics.leftColumnMinWidth
            + WorkspaceMetrics.centerColumnMinWidth
            + WorkspaceMetrics.resizableDividerHitWidth
        XCTAssertLessThanOrEqual(sum, 500)
    }

    /// 极窄：左右都收，仅中栏，绝不溢出。
    func testVeryNarrowPlanCollapsesBoth() {
        let plan = WorkspaceMetrics.columnVisibilityPlan(total: 300, wantLeft: true, wantRight: true)
        XCTAssertFalse(plan.showLeft); XCTAssertFalse(plan.showRight)
        XCTAssertLessThanOrEqual(WorkspaceMetrics.centerColumnMinWidth, 300)
    }

    /// 用户本就不想开右栏时，充足宽度也不强行展开。
    func testPlanRespectsUserIntent() {
        let plan = WorkspaceMetrics.columnVisibilityPlan(total: 1024, wantLeft: true, wantRight: false)
        XCTAssertTrue(plan.showLeft); XCTAssertFalse(plan.showRight)
    }

    // MARK: - #3 中间档 [494,668) lastRequested tiebreaker

    /// [494,668) 且左右都想要、最后点右 → 展开右栏（收左栏），右栏入口不再静默失效。
    func testMidBandBothWantedLastRightExpandsRight() {
        let plan = WorkspaceMetrics.columnVisibilityPlan(
            total: 500, wantLeft: true, wantRight: true, lastRequested: .right)
        XCTAssertFalse(plan.showLeft); XCTAssertTrue(plan.showRight)
    }

    /// [494,668) 且左右都想要、最后点左 → 展开左栏（收右栏）。
    func testMidBandBothWantedLastLeftExpandsLeft() {
        let plan = WorkspaceMetrics.columnVisibilityPlan(
            total: 500, wantLeft: true, wantRight: true, lastRequested: .left)
        XCTAssertTrue(plan.showLeft); XCTAssertFalse(plan.showRight)
    }

    /// [494,668) 只想要右栏（不要左）→ 展开右栏。
    func testMidBandOnlyRightExpandsRight() {
        let plan = WorkspaceMetrics.columnVisibilityPlan(
            total: 500, wantLeft: false, wantRight: true, lastRequested: .none)
        XCTAssertFalse(plan.showLeft); XCTAssertTrue(plan.showRight)
    }

    /// [454,494) 仅左+中可容纳：即便最后点右，右栏物理放不下 → 展开左栏。
    func testNarrowBandRightNotFittableFallsBackLeft() {
        // 454 <= 470 < 494（centerPlusRight=280+200+14=494）。
        let plan = WorkspaceMetrics.columnVisibilityPlan(
            total: 470, wantLeft: true, wantRight: true, lastRequested: .right)
        XCTAssertTrue(plan.showLeft); XCTAssertFalse(plan.showRight)
    }

    /// 全屏 834（竖）/ 1194（横）三栏齐全，不触发降级。
    func testFullscreenWidthsKeepAllThree() {
        for w in [CGFloat(834), CGFloat(1194)] {
            let plan = WorkspaceMetrics.columnVisibilityPlan(
                total: w, wantLeft: true, wantRight: true, lastRequested: .left)
            XCTAssertTrue(plan.showLeft, "w=\(w)"); XCTAssertTrue(plan.showRight, "w=\(w)")
        }
    }

    /// 极窄 320：列布局保持中栏，但右栏意图由覆盖层承接。
    func testUltraNarrowKeepsCenterOnly() {
        let plan = WorkspaceMetrics.columnVisibilityPlan(
            total: 320, wantLeft: true, wantRight: true, lastRequested: .right)
        XCTAssertFalse(plan.showLeft); XCTAssertFalse(plan.showRight)
        XCTAssertTrue(WorkspaceMetrics.shouldOverlayRight(
            total: 320, wantRight: true, plan: plan))
    }

    func testRightOverlayOnlyUsedBelowSideBySideThreshold() {
        let below = WorkspaceMetrics.columnVisibilityPlan(
            total: 493, wantLeft: true, wantRight: true, lastRequested: .right)
        XCTAssertTrue(WorkspaceMetrics.shouldOverlayRight(
            total: 493, wantRight: true, plan: below))

        let fits = WorkspaceMetrics.columnVisibilityPlan(
            total: 494, wantLeft: true, wantRight: true, lastRequested: .right)
        XCTAssertFalse(WorkspaceMetrics.shouldOverlayRight(
            total: 494, wantRight: true, plan: fits))
        XCTAssertFalse(WorkspaceMetrics.shouldOverlayRight(
            total: 320, wantRight: false, plan: below))
    }
}
