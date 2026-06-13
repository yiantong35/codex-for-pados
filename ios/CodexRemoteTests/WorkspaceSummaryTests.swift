import XCTest
@testable import CodexRemote

final class WorkspaceSummaryTests: XCTestCase {
    func testTurnPlanStepStatusFromRawString() {
        XCTAssertEqual(TurnPlanStepStatus(rawValue: "pending"), .pending)
        XCTAssertEqual(TurnPlanStepStatus(rawValue: "in_progress"), .inProgress)
        XCTAssertEqual(TurnPlanStepStatus(rawValue: "completed"), .completed)
        // 未知 / 缺省 → pending（容错，避免崩溃）
        XCTAssertEqual(TurnPlanStepStatus.from(any: nil), .pending)
        XCTAssertEqual(TurnPlanStepStatus.from(any: "bogus"), .pending)
    }

    func testTurnPlanStepEquatable() {
        let a = TurnPlanStep(step: "写测试", status: .inProgress)
        let b = TurnPlanStep(step: "写测试", status: .inProgress)
        XCTAssertEqual(a, b)
    }
}
