import XCTest
@testable import CodexRemote

final class ThreadReducerTests: XCTestCase {
    // delta 累积成完整文本，且 turn/completed 后不再运行
    func testAgentDeltaAccumulates() throws {
        var state = ConversationState(threadId: "t")
        let reducer = ThreadReducer()
        for n in try loadNotifs("agentDeltaSequence") { reducer.apply(n, to: &state) }
        guard case .agentMessage(_, let text)? = state.items.first else {
            return XCTFail("应有 agentMessage")
        }
        XCTAssertEqual(text, "Hello")
        XCTAssertFalse(state.isTurnRunning)   // turn/completed 后不再运行
    }

    func testTurnStartedMarksRunning() throws {
        var state = ConversationState(threadId: "t")
        let reducer = ThreadReducer()
        // 真实嵌套：turn id 在 params.turn.id
        reducer.apply(notif("turn/started", ["turn": ["id": "T9", "status": "inProgress"]]), to: &state)
        XCTAssertEqual(state.activeTurnId, "T9")
        XCTAssertTrue(state.isTurnRunning)
    }

    func testCommandOutputDeltaAppends() throws {
        var state = ConversationState(threadId: "t")
        let reducer = ThreadReducer()
        // item/started 嵌套；outputDelta 扁平（保持不变）
        reducer.apply(notif("item/started", ["item": ["id": "C1", "type": "commandExecution", "command": "ls"]]), to: &state)
        reducer.apply(notif("item/commandExecution/outputDelta", ["itemId": "C1", "delta": "a.txt\n"]), to: &state)
        reducer.apply(notif("item/commandExecution/outputDelta", ["itemId": "C1", "delta": "b.txt\n"]), to: &state)
        guard case .commandExecution(_, _, let out, _)? = state.items.first(where: { $0.id == "C1" }) else {
            return XCTFail("应有命令项")
        }
        XCTAssertEqual(out, "a.txt\nb.txt\n")
    }

    func testItemCompletedFinishesCommand() throws {
        var state = ConversationState(threadId: "t")
        let reducer = ThreadReducer()
        reducer.apply(notif("item/started", ["item": ["id": "C1", "type": "commandExecution", "command": "ls"]]), to: &state)
        reducer.apply(notif("item/completed", ["item": ["id": "C1", "type": "commandExecution", "status": "completed"]]), to: &state)
        guard case .commandExecution(_, _, _, let finished)? = state.items.first(where: { $0.id == "C1" }) else {
            return XCTFail("应有命令项")
        }
        XCTAssertTrue(finished)
    }

    func testTurnStartedReviewKindIsNonSteerable() throws {
        var state = ConversationState(threadId: "t")
        let reducer = ThreadReducer()
        // 若未来 turn 带 kind（review/compact），嵌套读 params.turn.kind 仍可识别为不可 steer。
        reducer.apply(notif("turn/started", ["turn": ["id": "T2", "kind": "review"]]), to: &state)
        XCTAssertEqual(state.activeTurnKind, .review)
    }

    func testFileChangeDiffUpdated() throws {
        var state = ConversationState(threadId: "t")
        let reducer = ThreadReducer()
        reducer.apply(notif("item/started", ["item": ["id": "F1", "type": "fileChange", "file": "a.swift"]]), to: &state)
        reducer.apply(notif("turn/diff/updated", ["itemId": "F1", "added": 3, "removed": 1, "diff": "@@"]), to: &state)
        guard case .fileChange(_, let file, let added, let removed, let diff)? = state.items.first(where: { $0.id == "F1" }) else {
            return XCTFail("应有文件改动项")
        }
        XCTAssertEqual(file, "a.swift")
        XCTAssertEqual(added, 3)
        XCTAssertEqual(removed, 1)
        XCTAssertEqual(diff, "@@")
    }

    // MARK: - 真实嵌套形状（realTurnSequence.json，本机 codex 0.133.0 实测录制）
    // 旧 reducer 读扁平 params.turnId / params.itemId / params.itemType / params.command，
    // 真实通知是嵌套 params.turn.* / params.item.*，故以下用例对旧实现应全部 RED。

    func testRealTurnStartedSetsActiveTurnIdFromNestedTurn() throws {
        var state = ConversationState(threadId: "019ec012-6dc3-72b0-bf8c-d54ca0527c21")
        let reducer = ThreadReducer()
        let notifs = try loadNotifs("realTurnSequence")
        // 只跑到 turn/started 之后断言 activeTurnId 已置位。
        let started = notifs.first { $0.method == "turn/started" }!
        reducer.apply(started, to: &state)
        XCTAssertEqual(state.activeTurnId, "019ec012-6e58-7540-9af5-d3d9f17df3fd")
        XCTAssertTrue(state.isTurnRunning)
        // 真实 turn/started 无 kind 字段，turn 应可 steer（kind=nil）。
        XCTAssertNil(state.activeTurnKind)
    }

    func testRealItemStartedCreatesCommandExecutionFromNestedItem() throws {
        var state = ConversationState(threadId: "019ec012-6dc3-72b0-bf8c-d54ca0527c21")
        let reducer = ThreadReducer()
        for n in try loadNotifs("realTurnSequence") {
            if n.method == "turn/completed" { break }   // 先只看进行中状态
            reducer.apply(n, to: &state)
        }
        guard case .commandExecution(_, let command, _, let finished)? =
                state.items.first(where: { $0.id == "call_ZPgSwOry2vW7rZMVDwOO91ta" }) else {
            return XCTFail("应出现 commandExecution 卡片（命令卡片不出现 = 滞后 bug）")
        }
        XCTAssertEqual(command, "/bin/zsh -lc 'echo hi'")
        // 序列里 item/completed(commandExecution).status == "completed" → finished 应为 true
        XCTAssertTrue(finished)
    }

    func testRealAgentMessageRendersFromNestedItem() throws {
        var state = ConversationState(threadId: "019ec012-6dc3-72b0-bf8c-d54ca0527c21")
        let reducer = ThreadReducer()
        for n in try loadNotifs("realTurnSequence") { reducer.apply(n, to: &state) }
        // agentMessage item/started(嵌套) 建项 + delta 累加 → 文本 "hi"
        guard let item = state.items.first(where: { $0.id == "msg_00aec26b5087dd7d016a2d131ea37081919b7a0be3ad13ee3f" }),
              case .agentMessage(_, let text) = item else {
            return XCTFail("应有 agentMessage")
        }
        XCTAssertEqual(text, "hi")
        // turn/completed 后不再运行
        XCTAssertFalse(state.isTurnRunning)
    }

    // helpers
    private func notif(_ m: String, _ p: [String: Any]) -> JSONRPCNotification {
        JSONRPCNotification(method: m, params: AnyCodable(p))
    }
    private func loadNotifs(_ name: String) throws -> [JSONRPCNotification] {
        let url = Bundle(for: type(of: self)).url(forResource: name, withExtension: "json")!
        let arr = try JSONDecoder().decode([JSONRPCNotification].self, from: Data(contentsOf: url))
        return arr
    }
}
