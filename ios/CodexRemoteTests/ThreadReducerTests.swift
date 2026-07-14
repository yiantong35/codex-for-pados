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
        guard case .commandExecution(_, _, let out, _, _, _)? = state.items.first(where: { $0.id == "C1" }) else {
            return XCTFail("应有命令项")
        }
        XCTAssertEqual(out, "a.txt\nb.txt\n")
    }

    func testItemStartedMarksCommandInProgress() throws {
        var state = ConversationState(threadId: "t")
        let reducer = ThreadReducer()
        reducer.apply(notif("item/started", ["item": ["id": "C1", "type": "commandExecution", "command": "ls"]]), to: &state)
        guard case .commandExecution(_, _, _, let status, _, _)? = state.items.first(where: { $0.id == "C1" }) else {
            return XCTFail("应有命令项")
        }
        XCTAssertEqual(status, .inProgress)
    }

    func testItemCompletedLandsStatusExitCodeDuration() throws {
        var state = ConversationState(threadId: "t")
        let reducer = ThreadReducer()
        reducer.apply(notif("item/started", ["item": ["id": "C1", "type": "commandExecution", "command": "ls"]]), to: &state)
        reducer.apply(notif("item/completed", ["item": ["id": "C1", "type": "commandExecution",
                                                        "status": "completed", "exitCode": 0, "durationMs": 42]]), to: &state)
        guard case .commandExecution(_, _, _, let status, let exitCode, let durationMs)? = state.items.first(where: { $0.id == "C1" }) else {
            return XCTFail("应有命令项")
        }
        XCTAssertEqual(status, .completed)
        XCTAssertEqual(exitCode, 0)
        XCTAssertEqual(durationMs, 42)
    }

    func testItemCompletedFailedStatusWithNonzeroExitCode() throws {
        var state = ConversationState(threadId: "t")
        let reducer = ThreadReducer()
        reducer.apply(notif("item/started", ["item": ["id": "C1", "type": "commandExecution", "command": "false"]]), to: &state)
        reducer.apply(notif("item/completed", ["item": ["id": "C1", "type": "commandExecution",
                                                        "status": "failed", "exitCode": 1, "durationMs": 7]]), to: &state)
        guard case .commandExecution(_, _, _, let status, let exitCode, _)? = state.items.first(where: { $0.id == "C1" }) else {
            return XCTFail("应有命令项")
        }
        XCTAssertEqual(status, .failed)
        XCTAssertEqual(exitCode, 1)
    }

    func testCommandCountDerivesFromItems() throws {
        var state = ConversationState(threadId: "t")
        let reducer = ThreadReducer()
        XCTAssertEqual(state.commandCount, 0)
        reducer.apply(notif("item/started", ["item": ["id": "C1", "type": "commandExecution", "command": "ls"]]), to: &state)
        reducer.apply(notif("item/started", ["item": ["id": "C2", "type": "commandExecution", "command": "pwd"]]), to: &state)
        reducer.apply(notif("item/started", ["item": ["id": "M1", "type": "agentMessage", "text": "hi"]]), to: &state)
        XCTAssertEqual(state.commandCount, 2)   // 只数 commandExecution，agentMessage 不计
    }

    func testTurnStartedReviewKindIsNonSteerable() throws {
        var state = ConversationState(threadId: "t")
        let reducer = ThreadReducer()
        // 若未来 turn 带 kind（review/compact），嵌套读 params.turn.kind 仍可识别为不可 steer。
        reducer.apply(notif("turn/started", ["turn": ["id": "T2", "kind": "review"]]), to: &state)
        XCTAssertEqual(state.activeTurnKind, .review)
    }

    // Task 3: turn/diff/updated → state.turnDiff（无 itemId，不再更新 fileChange item）
    func testTurnDiffUpdatedStoresFullDiff() {
        // turn/diff/updated 无 itemId，必须不被丢弃，直接存入 state.turnDiff
        let diff = "diff --git a/a.swift b/a.swift\n--- a/a.swift\n+++ b/a.swift\n@@ -0,0 +1 @@\n+hello"
        var state = ConversationState(threadId: "t")
        let n = notif("turn/diff/updated", ["threadId": "t", "turnId": "turn1", "diff": diff])
        ThreadReducer().apply(n, to: &state)
        XCTAssertEqual(state.turnDiff, diff)
    }

    func testFileChangePatchUpdatedStoresPerFileDiff() {
        // fileChange/patchUpdated：先有 fileChange item，patch 带 changes[].diff，按 path 落入 diff 文本
        var state = ConversationState(threadId: "t")
        state.items = [.fileChange(id: "i1", file: "a.swift", added: 0, removed: 0, diff: "")]
        let fileDiff = "--- a/a.swift\n+++ b/a.swift\n@@ -0,0 +1 @@\n+x"
        let n = notif("item/fileChange/patchUpdated", [
            "threadId": "t", "turnId": "turn1", "itemId": "i1",
            "changes": [["path": "a.swift", "kind": ["type": "update"], "diff": fileDiff]] as [[String: Any]]
        ])
        ThreadReducer().apply(n, to: &state)
        guard case .fileChange(_, let file, let added, _, let storedDiff) = state.items[0] else {
            return XCTFail("expected fileChange")
        }
        XCTAssertEqual(file, "a.swift")
        XCTAssertEqual(added, 1)         // 从 changes[].diff 解析得 +1
        XCTAssertEqual(storedDiff, fileDiff) // 存了该文件的 diff 文本
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
        guard case .commandExecution(_, let command, _, let status, let exitCode, let durationMs)? =
                state.items.first(where: { $0.id == "call_ZPgSwOry2vW7rZMVDwOO91ta" }) else {
            return XCTFail("应出现 commandExecution 卡片（命令卡片不出现 = 滞后 bug）")
        }
        XCTAssertEqual(command, "/bin/zsh -lc 'echo hi'")
        // 序列里 item/completed(commandExecution): status=completed, exitCode=0, durationMs=0
        XCTAssertEqual(status, .completed)
        XCTAssertEqual(exitCode, 0)
        XCTAssertEqual(durationMs, 0)
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

    // MARK: - 批3·思考/推理（reasoning item + textDelta/summaryTextDelta 累加）

    // item/started(type=reasoning) 应创建一条 reasoning item（即使 summary/content 为空）。
    func testReasoningItemStartedCreatesReasoningItem() throws {
        var state = ConversationState(threadId: "t")
        let reducer = ThreadReducer()
        reducer.apply(notif("item/started", ["item": ["id": "R1", "type": "reasoning",
                                                       "summary": [], "content": []]]), to: &state)
        guard case .reasoning(_, let text)? = state.items.first(where: { $0.id == "R1" }) else {
            return XCTFail("应出现 reasoning 卡片")
        }
        XCTAssertEqual(text, "")   // 无内容时为空串（UI 显「正在思考…」占位）
    }

    // item/reasoning/textDelta 按 itemId 累加正文（字段扁平 itemId/delta，见 ReasoningTextDeltaNotification.ts）。
    func testReasoningTextDeltaAccumulates() throws {
        var state = ConversationState(threadId: "t")
        let reducer = ThreadReducer()
        reducer.apply(notif("item/started", ["item": ["id": "R1", "type": "reasoning",
                                                       "summary": [], "content": []]]), to: &state)
        reducer.apply(notif("item/reasoning/textDelta", ["itemId": "R1", "delta": "Let me "]), to: &state)
        reducer.apply(notif("item/reasoning/textDelta", ["itemId": "R1", "delta": "think"]), to: &state)
        guard case .reasoning(_, let text)? = state.items.first(where: { $0.id == "R1" }) else {
            return XCTFail("应出现 reasoning 卡片")
        }
        XCTAssertEqual(text, "Let me think")
    }

    // item/reasoning/summaryTextDelta 也累加进同一 reasoning item（字段扁平 itemId/delta）。
    func testReasoningSummaryTextDeltaAccumulates() throws {
        var state = ConversationState(threadId: "t")
        let reducer = ThreadReducer()
        reducer.apply(notif("item/started", ["item": ["id": "R1", "type": "reasoning",
                                                       "summary": [], "content": []]]), to: &state)
        reducer.apply(notif("item/reasoning/summaryTextDelta", ["itemId": "R1", "delta": "Plan: "]), to: &state)
        reducer.apply(notif("item/reasoning/summaryTextDelta", ["itemId": "R1", "delta": "do X"]), to: &state)
        guard case .reasoning(_, let text)? = state.items.first(where: { $0.id == "R1" }) else {
            return XCTFail("应出现 reasoning 卡片")
        }
        XCTAssertEqual(text, "Plan: do X")
    }

    // textDelta 先于 item/started 到达时也应建项（与 agentMessageDelta 容错一致）。
    func testReasoningTextDeltaBeforeStartedCreatesItem() throws {
        var state = ConversationState(threadId: "t")
        let reducer = ThreadReducer()
        reducer.apply(notif("item/reasoning/textDelta", ["itemId": "R1", "delta": "early"]), to: &state)
        guard case .reasoning(_, let text)? = state.items.first(where: { $0.id == "R1" }) else {
            return XCTFail("应出现 reasoning 卡片")
        }
        XCTAssertEqual(text, "early")
    }

    // 真实 fixture（含 type=reasoning 的 item/started·completed）应产出 reasoning item。
    func testRealReasoningItemAppears() throws {
        var state = ConversationState(threadId: "019ec012-6dc3-72b0-bf8c-d54ca0527c21")
        let reducer = ThreadReducer()
        for n in try loadNotifs("realTurnSequence") { reducer.apply(n, to: &state) }
        guard case .reasoning? = state.items.first(where: { $0.id == "rs_06f0c5b78c40c04e016a2d1311aed08191abbe4c635e6fffe4" }) else {
            return XCTFail("真实序列里的 reasoning item 应出现")
        }
    }

    func testTurnPlanUpdatedPopulatesPlan() throws {
        var state = ConversationState(threadId: "t")
        let reducer = ThreadReducer()
        reducer.apply(notif("turn/plan/updated", ["plan": [
            ["step": "读代码", "status": "completed"],
            ["step": "写测试", "status": "in_progress"],
            ["step": "实现", "status": "pending"],
        ]]), to: &state)
        XCTAssertEqual(state.plan, [
            TurnPlanStep(step: "读代码", status: .completed),
            TurnPlanStep(step: "写测试", status: .inProgress),
            TurnPlanStep(step: "实现", status: .pending),
        ])
    }

    func testTurnPlanUpdatedReplacesPreviousPlan() throws {
        var state = ConversationState(threadId: "t")
        let reducer = ThreadReducer()
        reducer.apply(notif("turn/plan/updated", ["plan": [["step": "旧", "status": "pending"]]]), to: &state)
        reducer.apply(notif("turn/plan/updated", ["plan": [["step": "新", "status": "completed"]]]), to: &state)
        // plan 是整体快照，后到的覆盖先到的（不累加）
        XCTAssertEqual(state.plan, [TurnPlanStep(step: "新", status: .completed)])
    }

    // MARK: - Task 2: ConversationState.turnDiff 字段

    func testConversationStateTurnDiffDefaultsEmpty() {
        let state = ConversationState(threadId: "t")
        XCTAssertEqual(state.turnDiff, "")
    }

    // D4：非发起端收不到 turn/started，但 item/started 应驱动运行态为真
    func testRunningDrivenByItemStartedWithoutTurnStarted() {
        var state = ConversationState(threadId: "t")
        let reducer = ThreadReducer()
        // 未发 turn/started（模拟非发起端）
        reducer.apply(notif("item/started", ["item": ["id": "A1", "type": "agentMessage"]]), to: &state)
        XCTAssertTrue(state.isTurnRunning, "有进行中 item 应为运行态，即使没收到 turn/started")
    }

    // D4：全部 item completed 后归闲置
    func testRunningClearsWhenAllItemsCompleted() {
        var state = ConversationState(threadId: "t")
        let reducer = ThreadReducer()
        reducer.apply(notif("item/started", ["item": ["id": "A1", "type": "agentMessage"]]), to: &state)
        reducer.apply(notif("item/started", ["item": ["id": "C1", "type": "commandExecution", "command": "ls"]]), to: &state)
        XCTAssertTrue(state.isTurnRunning)
        reducer.apply(notif("item/completed", ["item": ["id": "A1", "type": "agentMessage"]]), to: &state)
        XCTAssertTrue(state.isTurnRunning, "还有一个 item 进行中")
        reducer.apply(notif("item/completed", ["item": ["id": "C1", "type": "commandExecution", "command": "ls", "status": "completed"]]), to: &state)
        XCTAssertFalse(state.isTurnRunning, "全部 item completed 后应归闲置")
    }

    // D4：turn/completed 兜底清空（防残留 item 计数）
    func testTurnCompletedClearsInFlight() {
        var state = ConversationState(threadId: "t")
        let reducer = ThreadReducer()
        reducer.apply(notif("item/started", ["item": ["id": "A1", "type": "agentMessage"]]), to: &state)
        reducer.apply(notif("turn/completed", ["turn": ["id": "T1", "status": "completed"]]), to: &state)
        XCTAssertFalse(state.isTurnRunning, "turn/completed 应兜底清空进行中 item")
    }

    // MARK: - Task 1: 统一解析 + reasoning 修复 + unknown 降级

    // D3：reasoning content 为 v2 Array<string> 形态时应解析出文字（非空）。
    func testReasoningArrayOfStringsParses() {
        var s = ConversationState(threadId: "t")
        ThreadReducer().apply(notif("item/completed", ["item": [
            "id": "R1", "type": "reasoning",
            "content": ["先看代码", "再改"] as [String]
        ]]), to: &s)
        guard case .reasoning(_, let text)? = s.items.first(where: { $0.id == "R1" }) else {
            return XCTFail("应有 reasoning")
        }
        XCTAssertEqual(text, "先看代码\n再改")
    }

    // D3：遗留 [{type,text}] 形态仍可解析（兼容不回归）。
    func testReasoningLegacyDictArrayStillParses() {
        var s = ConversationState(threadId: "t")
        ThreadReducer().apply(notif("item/completed", ["item": [
            "id": "R2", "type": "reasoning",
            "content": [["type": "text", "text": "旧格式"]] as [[String: Any]]
        ]]), to: &s)
        guard case .reasoning(_, let text)? = s.items.first(where: { $0.id == "R2" }) else {
            return XCTFail("应有 reasoning")
        }
        XCTAssertEqual(text, "旧格式")
    }

    // D4：未识别 type → .unknown(id,type)，绝不丢弃。
    func testUnknownTypeBecomesUnknownItem() {
        let item: [String: Any] = ["id": "U1", "type": "someFutureType"]
        guard case .unknown(let id, let type)? = ThreadReducer().parseItem(item) else {
            return XCTFail("未知 type 应产出 .unknown")
        }
        XCTAssertEqual(id, "U1")
        XCTAssertEqual(type, "someFutureType")
    }

    // D4：unknown 也真正进入 history items（不 default:break 丢弃）。
    func testUnknownTypeIngestedInHistory() {
        let s = historyItems(["id": "U1", "type": "someFutureType"])
        guard case .unknown? = s.items.first else { return XCTFail("unknown 应被摄入") }
    }

    // D2 核心回归：同一 item dict 经 live 与 history 两路，产出一致的 items。
    func testLiveAndHistoryProduceSameItemForStaticType() {
        let item: [String: Any] = [
            "id": "W1", "type": "webSearch", "query": "swift enum", "action": "search"
        ]
        XCTAssertEqual(liveItems(item).items, historyItems(item).items)
    }

    // MARK: - Task 2: 命令/文件历史补齐

    // history commandExecution 解析出 command/status/exitCode/durationMs，与 live 一致。
    func testHistoryCommandExecutionMatchesLive() {
        let item: [String: Any] = [
            "id": "C9", "type": "commandExecution", "command": "/bin/zsh -lc 'echo hi'",
            "aggregatedOutput": "hi\n", "status": "completed", "exitCode": 0, "durationMs": 12
        ]
        let h = historyItems(item)
        guard case .commandExecution(_, let cmd, let out, let st, let ec, let dm)? = h.items.first else {
            return XCTFail("history 应有命令项")
        }
        XCTAssertEqual(cmd, "/bin/zsh -lc 'echo hi'")
        XCTAssertEqual(out, "hi\n")
        XCTAssertEqual(st, .completed)
        XCTAssertEqual(ec, 0)
        XCTAssertEqual(dm, 12)
        XCTAssertEqual(liveItems(item).items, h.items)   // 两路一致
    }

    // fileChange 多文件：合并 diff、增删行数求和。
    func testHistoryFileChangeMultiFile() {
        let diffA = "diff --git a/a.swift b/a.swift\n--- a/a.swift\n+++ b/a.swift\n@@ -0,0 +1 @@\n+x"
        let diffB = "diff --git a/b.swift b/b.swift\n--- a/b.swift\n+++ b/b.swift\n@@ -0,0 +2 @@\n+y\n+z"
        let item: [String: Any] = [
            "id": "F1", "type": "fileChange",
            "changes": [
                ["path": "a.swift", "kind": ["type": "update"], "diff": diffA],
                ["path": "b.swift", "kind": ["type": "add"], "diff": diffB],
            ] as [[String: Any]]
        ]
        let s = historyItems(item)
        guard case .fileChange(_, let file, let added, _, let diff)? = s.items.first else {
            return XCTFail("应有 fileChange")
        }
        XCTAssertEqual(file, "a.swift")            // 首文件名
        XCTAssertEqual(added, 3)                   // +x(1) + y,z(2) = 3
        XCTAssertTrue(diff.contains("a.swift") && diff.contains("b.swift"))  // 合并含两文件
    }

    // MARK: - Task 3: 工具调用类解析

    func testMcpToolCallParses() {
        guard case .mcpToolCall(let id, let server, let tool, let status, let result, let dm)? =
            ThreadReducer().parseItem([
                "id": "M1", "type": "mcpToolCall", "server": "fs", "tool": "read",
                "status": "completed", "result": "ok", "durationMs": 8
            ]) else { return XCTFail("应解析 mcpToolCall") }
        XCTAssertEqual([id, server, tool, status, result], ["M1", "fs", "read", "completed", "ok"])
        XCTAssertEqual(dm, 8)
    }

    func testDynamicToolCallParses() {
        guard case .dynamicToolCall(_, let ns, let tool, let status, let success)? =
            ThreadReducer().parseItem([
                "id": "D1", "type": "dynamicToolCall", "namespace": "shell",
                "tool": "exec", "status": "completed", "success": true
            ]) else { return XCTFail("应解析 dynamicToolCall") }
        XCTAssertEqual([ns, tool, status], ["shell", "exec", "completed"])
        XCTAssertEqual(success, true)
    }

    func testWebSearchParses() {
        guard case .webSearch(_, let query, let action)? =
            ThreadReducer().parseItem([
                "id": "W1", "type": "webSearch", "query": "swift", "action": "search"
            ]) else { return XCTFail("应解析 webSearch") }
        XCTAssertEqual([query, action], ["swift", "search"])
    }

    // 缺省容错：单字段缺失不丢整条。
    func testMcpToolCallMissingFieldsDefaults() {
        guard case .mcpToolCall(_, let server, _, _, let result, let dm)? =
            ThreadReducer().parseItem(["id": "M2", "type": "mcpToolCall", "tool": "x"]) else {
            return XCTFail("缺字段也应产出 mcpToolCall")
        }
        XCTAssertEqual(server, "")
        XCTAssertEqual(result, "")
        XCTAssertNil(dm)
    }

    // helpers
    private func notif(_ m: String, _ p: [String: Any]) -> JSONRPCNotification {
        JSONRPCNotification(method: m, params: AnyCodable(p))
    }
    // 走 live 两拍（started+completed）摄入单个 item dict。
    private func liveItems(_ item: [String: Any]) -> ConversationState {
        var s = ConversationState(threadId: "t")
        let r = ThreadReducer()
        r.apply(notif("item/started", ["item": item]), to: &s)
        r.apply(notif("item/completed", ["item": item]), to: &s)
        return s
    }
    // 走 history 摄入单个 item dict。
    private func historyItems(_ item: [String: Any]) -> ConversationState {
        var s = ConversationState(threadId: "t")
        ThreadReducer().ingest(resumeResult: ["thread": ["turns": [["items": [item]]]]], to: &s)
        return s
    }
    private func loadNotifs(_ name: String) throws -> [JSONRPCNotification] {
        let url = Bundle(for: type(of: self)).url(forResource: name, withExtension: "json")!
        let arr = try JSONDecoder().decode([JSONRPCNotification].self, from: Data(contentsOf: url))
        return arr
    }
}
