import XCTest
@testable import CodexRemote

/// #3（能耗）：流式攒批**按需调度**（非常驻 30Hz 循环）验收。
///
/// 三条不变量：
///   1. 活跃流：连续 delta 到达后，攒批在一个调度周期内合并落地（逐字一致、不丢帧）。
///   2. 空闲：flush 完成后不再有周期性变化——快照两次相等即证明无常驻循环重复发布。
///   3. 停止观察：仍有未 flush 的攒批内容时 stopObserving 强制最后一次 flush，尾字不丢。
@MainActor
final class ConversationCoalesceSchedulingTests: XCTestCase {

    private func makeStore() async -> (ConversationStore, MockTransport) {
        let mock = MockTransport()
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()
        let store = ConversationStore(rpc: rpc, threadId: "t")
        await store.startObserving()
        return (store, mock)
    }

    /// 活跃：连续 delta 到达后，攒批在一个调度周期内合并落地（逐字一致）。
    func test_active_deltas_flush_within_one_cycle() async throws {
        let (store, mock) = await makeStore()
        await mock.feed(#"{"method":"item/started","params":{"item":{"id":"a1","type":"agentMessage","text":""}}}"#)
        for d in ["Hel", "lo, ", "世界"] {
            await mock.feed(#"{"method":"item/agentMessage/delta","params":{"itemId":"a1","delta":"\#(d)"}}"#)
        }
        // 等待一次 33ms 调度周期 + 余量后，攒批应已合并落地。
        try await waitUntil {
            if case .agentMessage(_, let t)? = store.state.items.first(where: { $0.id == "a1" }) {
                return t == "Hello, 世界"
            }
            return false
        }
        guard case .agentMessage(_, let text)? = store.state.items.first(where: { $0.id == "a1" }) else {
            return XCTFail("应有 a1")
        }
        XCTAssertEqual(text, "Hello, 世界")   // 逐字一致，不丢帧
    }

    /// 空闲：flush 完成后不再有周期性变化——快照两次相等即证明无常驻循环重复发布。
    func test_idle_no_periodic_wakeups() async throws {
        let (store, mock) = await makeStore()
        await mock.feed(#"{"method":"item/started","params":{"item":{"id":"a1","type":"agentMessage","text":""}}}"#)
        await mock.feed(#"{"method":"item/agentMessage/delta","params":{"itemId":"a1","delta":"X"}}"#)
        // 先等落地。
        try await waitUntil {
            if case .agentMessage(_, let t)? = store.state.items.first(where: { $0.id == "a1" }) {
                return t == "X"
            }
            return false
        }
        let snap1 = store.state.items
        // 空闲窗口内不应再有周期性 drain/发布。
        try await Task.sleep(nanoseconds: 300_000_000)
        let snap2 = store.state.items
        XCTAssertEqual(snap1.count, snap2.count)
        guard case .agentMessage(_, let t1)? = snap1.first, case .agentMessage(_, let t2)? = snap2.first
        else { return XCTFail("应有 a1") }
        XCTAssertEqual(t1, t2)   // 空闲期间无变化（无周期性 drain 覆盖）
        // 关键不变量：空闲时无 pending 调度任务（零唤醒）。
        XCTAssertFalse(store.hasPendingFlushForTesting)
    }

    /// 停止观察：仍有未 flush 的攒批内容时 stopObserving 强制最后一次 flush，尾字不丢。
    func test_stopObserving_flushes_tail() async throws {
        let (store, mock) = await makeStore()
        await mock.feed(#"{"method":"item/started","params":{"item":{"id":"a1","type":"agentMessage","text":""}}}"#)
        await mock.feed(#"{"method":"item/agentMessage/delta","params":{"itemId":"a1","delta":"TAIL"}}"#)
        // 等 started + delta 都进入 reducer（delta 入 coalescer 缓冲，尚未 flush）。
        try await waitUntil { store.hasPendingFlushForTesting }
        // 不等待调度周期，立即停止：兜底 flush 必须把 TAIL 落地。
        store.stopObserving()
        guard case .agentMessage(_, let text)? = store.state.items.first(where: { $0.id == "a1" }) else {
            return XCTFail("应有 a1")
        }
        XCTAssertEqual(text, "TAIL")
        // 兜底后 pending 调度必须已清除。
        XCTAssertFalse(store.hasPendingFlushForTesting)
    }

    // MARK: - helper
    private func waitUntil(timeout: TimeInterval = 2.0,
                           _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("waitUntil timed out")
    }
}
