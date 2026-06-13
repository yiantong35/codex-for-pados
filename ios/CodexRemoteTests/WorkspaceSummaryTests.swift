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

    func testDiffLineCountsSumsAllFileChanges() {
        var state = ConversationState(threadId: "t")
        state.items = [
            .userMessage(id: "u1", text: "hi"),
            .fileChange(id: "f1", file: "a.swift", added: 10, removed: 3, diff: ""),
            .fileChange(id: "f2", file: "b.swift", added: 0, removed: 5, diff: ""),
            .agentMessage(id: "a1", text: "done"),
        ]
        let counts = WorkspaceSummary.diffLineCounts(in: state)
        XCTAssertEqual(counts.added, 10)
        XCTAssertEqual(counts.removed, 8)
        XCTAssertEqual(counts.changedFiles, 2)
    }

    func testDiffLineCountsEmptyWhenNoFileChanges() {
        var state = ConversationState(threadId: "t")
        state.items = [.userMessage(id: "u1", text: "hi")]
        let counts = WorkspaceSummary.diffLineCounts(in: state)
        XCTAssertEqual(counts.added, 0)
        XCTAssertEqual(counts.removed, 0)
        XCTAssertEqual(counts.changedFiles, 0)
        XCTAssertTrue(counts.isEmpty)
    }

    func testPlanProgressCountsCompleted() {
        var state = ConversationState(threadId: "t")
        state.plan = [
            TurnPlanStep(step: "a", status: .completed),
            TurnPlanStep(step: "b", status: .completed),
            TurnPlanStep(step: "c", status: .inProgress),
        ]
        let p = WorkspaceSummary.planProgress(in: state)
        XCTAssertEqual(p.completed, 2)
        XCTAssertEqual(p.total, 3)
        XCTAssertEqual(p.steps.count, 3)
        XCTAssertFalse(p.isEmpty)
    }

    func testPlanProgressEmpty() {
        let state = ConversationState(threadId: "t")
        let p = WorkspaceSummary.planProgress(in: state)
        XCTAssertEqual(p.completed, 0)
        XCTAssertEqual(p.total, 0)
        XCTAssertTrue(p.isEmpty)
    }

    func testCommandTasksListsCommandsInOrder() {
        var state = ConversationState(threadId: "t")
        state.items = [
            .commandExecution(id: "c1", command: "ls -la", output: "", status: .completed, exitCode: 0, durationMs: 5),
            .agentMessage(id: "a1", text: "x"),
            .commandExecution(id: "c2", command: "swift build", output: "", status: .inProgress, exitCode: nil, durationMs: nil),
        ]
        let tasks = WorkspaceSummary.commandTasks(in: state)
        XCTAssertEqual(tasks.map(\.command), ["ls -la", "swift build"])
        XCTAssertEqual(tasks.first?.status, .completed)
        XCTAssertEqual(tasks.last?.status, .inProgress)
    }

    func testCommandTasksEmpty() {
        var state = ConversationState(threadId: "t")
        state.items = [.userMessage(id: "u1", text: "hi")]
        XCTAssertTrue(WorkspaceSummary.commandTasks(in: state).isEmpty)
    }
}
