import XCTest
@testable import CodexRemote

/// F8：流式增量攒批（StreamCoalescer + reducer applyCoalesced）保真测试。
///
/// 核心不变量：**攒批合流结果与逐 token 立即追加逐字一致**（不丢字/不错序/不重复），
/// 且覆盖「保真陷阱」——非 delta 事件（item/completed 等）处理前必须先把已缓冲 delta 落地，
/// 否则读到滞后文本会误决策（如 finishReasoning 空 → 误填 fallback → flush 后双重追加）。
final class StreamCoalescerTests: XCTestCase {

    // MARK: - 1. StreamCoalescer 类：就地追加逐字一致 + drain 清空

    func test_coalesced_output_byte_identical_to_per_token_append() {
        let deltas = ["Hel", "lo, ", "wor", "ld", "! 你", "好"]
        // 逐 token 追加基准
        var naive = ""; deltas.forEach { naive += $0 }
        // coalescer：全部 append 后一次 drain
        let c = StreamCoalescer()
        deltas.forEach { c.append(id: "a1", kind: .agent, delta: $0) }
        let drained = c.drain()
        XCTAssertEqual(drained["a1"]?.text, naive)   // 逐字一致
        XCTAssertEqual(drained["a1"]?.kind, .agent)  // kind 保留
        XCTAssertTrue(c.isEmpty)                      // drain 后清空
        XCTAssertTrue(c.drain().isEmpty)              // 再 drain 无残留
    }

    // 多 id 独立缓冲，互不串扰。
    func test_coalescer_multiple_ids_independent() {
        let c = StreamCoalescer()
        c.append(id: "a", kind: .agent, delta: "AA")
        c.append(id: "b", kind: .reasoning, delta: "BB")
        c.append(id: "a", kind: .agent, delta: "CC")
        let drained = c.drain()
        XCTAssertEqual(drained["a"]?.text, "AACC")
        XCTAssertEqual(drained["b"]?.text, "BB")
        XCTAssertEqual(drained["b"]?.kind, .reasoning)
    }

    // MARK: - 2. reducer 攒批合流 == 逐 token 追加（含保真陷阱覆盖）

    /// agentMessage：item/started → 多条 delta → turn/completed（非 delta，触发 drain）。
    /// 最终 a1 文本必须逐字等于把同样 delta 逐条立即追加得到的基准。
    @MainActor
    func test_reducer_agent_started_deltas_completed_matches_sequential() {
        let deltas = ["Hel", "lo, ", "wor", "ld", "! 你", "好"]
        let baseline = deltas.reduce("", +)   // 逐 token 立即追加基准

        var state = ConversationState(threadId: "t")
        let reducer = ThreadReducer()
        reducer.apply(notif("item/started", ["item": ["id": "a1", "type": "agentMessage", "text": ""]]), to: &state)
        for d in deltas {
            reducer.apply(notif("item/agentMessage/delta", ["itemId": "a1", "delta": d]), to: &state)
        }
        // 非 delta 事件触发 drain-then-apply（保真锚）。
        reducer.apply(notif("turn/completed", ["turn": ["id": "T1", "status": "completed"]]), to: &state)

        guard case .agentMessage(_, let text)? = state.items.first(where: { $0.id == "a1" }) else {
            return XCTFail("应有 agentMessage a1")
        }
        XCTAssertEqual(text, baseline)                 // 逐字一致
        XCTAssertEqual(state.items.count, 1)           // 顺序/数量不变
    }

    /// 保真陷阱：reasoning started → 多条 textDelta → item/completed（带 fallback summary）。
    /// item/completed 是非 delta：必须先 drain 把 delta 落地，使 finishReasoning 读到非空文本，
    /// 从而**不误填 fallback**、**不双重追加**。最终文本 == 逐 token 追加（而非 fallback）。
    @MainActor
    func test_reducer_reasoning_completed_with_fallback_no_double_append() {
        let deltas = ["Let ", "me ", "think ", "步骤一", "步骤二"]
        let baseline = deltas.reduce("", +)

        var state = ConversationState(threadId: "t")
        let reducer = ThreadReducer()
        reducer.apply(notif("item/started", ["item": ["id": "r1", "type": "reasoning",
                                                       "summary": [], "content": []]]), to: &state)
        for d in deltas {
            reducer.apply(notif("item/reasoning/textDelta", ["itemId": "r1", "delta": d]), to: &state)
        }
        // item/completed 带 fallback summary（若 delta 未先落地，会被误当作最终文本或叠加）。
        reducer.apply(notif("item/completed", ["item": ["id": "r1", "type": "reasoning",
                                                        "summary": [["type": "text", "text": "FALLBACK-不该出现"]] as [[String: Any]]]]), to: &state)

        guard case .reasoning(_, let text)? = state.items.first(where: { $0.id == "r1" }) else {
            return XCTFail("应有 reasoning r1")
        }
        XCTAssertEqual(text, baseline)                       // == 逐 token 追加
        XCTAssertFalse(text.contains("FALLBACK"))            // 未误填 fallback
        XCTAssertEqual(text.components(separatedBy: "步骤一").count - 1, 1)  // 无重复追加
    }

    /// 完成态 aggregatedOutput 是服务端权威全文，替换可能漏收/截断的 delta。
    @MainActor
    func test_reducer_command_completed_with_fallback_uses_delta_output() {
        let deltas = ["a.txt\n", "b.txt\n", "c.txt\n"]

        var state = ConversationState(threadId: "t")
        let reducer = ThreadReducer()
        reducer.apply(notif("item/started", ["item": ["id": "c1", "type": "commandExecution", "command": "ls"]]), to: &state)
        for d in deltas {
            reducer.apply(notif("item/commandExecution/outputDelta", ["itemId": "c1", "delta": d]), to: &state)
        }
        reducer.apply(notif("item/completed", ["item": ["id": "c1", "type": "commandExecution",
                                                        "status": "completed", "exitCode": 0, "durationMs": 5,
                                                        "aggregatedOutput": "AUTHORITATIVE-FULL"]]), to: &state)

        guard case .commandExecution(_, _, let out, _, let st, let ec, _)? = state.items.first(where: { $0.id == "c1" }) else {
            return XCTFail("应有 commandExecution c1")
        }
        XCTAssertEqual(out, "AUTHORITATIVE-FULL")
        XCTAssertEqual(st, .completed)         // 完成态字段照常落地
        XCTAssertEqual(ec, 0)
    }

    /// 攒批直接调用 applyCoalesced：drain 后一次并入，文本 == t + 缓冲文本。
    @MainActor
    func test_applyCoalesced_lands_buffered_text_once() {
        var state = ConversationState(threadId: "t")
        state.items = [.agentMessage(id: "a1", text: "PRE-")]
        let reducer = ThreadReducer()
        reducer.coalescer.append(id: "a1", kind: .agent, delta: "X")
        reducer.coalescer.append(id: "a1", kind: .agent, delta: "Y")
        reducer.applyCoalesced(reducer.coalescer.drain(), &state)
        guard case .agentMessage(_, let text)? = state.items.first else { return XCTFail("应有 a1") }
        XCTAssertEqual(text, "PRE-XY")
        XCTAssertTrue(reducer.coalescer.isEmpty)
    }

    // MARK: - helper
    private func notif(_ m: String, _ p: [String: Any]) -> JSONRPCNotification {
        JSONRPCNotification(method: m, params: AnyCodable(p))
    }
}
