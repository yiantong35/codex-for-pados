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
        reducer.apply(notif("turn/started", ["turnId": "T9"]), to: &state)
        XCTAssertEqual(state.activeTurnId, "T9")
        XCTAssertTrue(state.isTurnRunning)
    }

    func testCommandOutputDeltaAppends() throws {
        var state = ConversationState(threadId: "t")
        let reducer = ThreadReducer()
        reducer.apply(notif("item/started", ["itemId": "C1", "itemType": "commandExecution", "command": "ls"]), to: &state)
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
        reducer.apply(notif("item/started", ["itemId": "C1", "itemType": "commandExecution", "command": "ls"]), to: &state)
        reducer.apply(notif("item/completed", ["itemId": "C1"]), to: &state)
        guard case .commandExecution(_, _, _, let finished)? = state.items.first(where: { $0.id == "C1" }) else {
            return XCTFail("应有命令项")
        }
        XCTAssertTrue(finished)
    }

    func testTurnStartedReviewKindIsNonSteerable() throws {
        var state = ConversationState(threadId: "t")
        let reducer = ThreadReducer()
        reducer.apply(notif("turn/started", ["turnId": "T2", "kind": "review"]), to: &state)
        XCTAssertEqual(state.activeTurnKind, .review)
    }

    func testFileChangeDiffUpdated() throws {
        var state = ConversationState(threadId: "t")
        let reducer = ThreadReducer()
        reducer.apply(notif("item/started", ["itemId": "F1", "itemType": "fileChange", "file": "a.swift"]), to: &state)
        reducer.apply(notif("turn/diff/updated", ["itemId": "F1", "added": 3, "removed": 1, "diff": "@@"]), to: &state)
        guard case .fileChange(_, let file, let added, let removed, let diff)? = state.items.first(where: { $0.id == "F1" }) else {
            return XCTFail("应有文件改动项")
        }
        XCTAssertEqual(file, "a.swift")
        XCTAssertEqual(added, 3)
        XCTAssertEqual(removed, 1)
        XCTAssertEqual(diff, "@@")
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
