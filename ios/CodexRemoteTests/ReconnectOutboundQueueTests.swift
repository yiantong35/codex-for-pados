import XCTest
@testable import CodexRemote

@MainActor
final class ReconnectOutboundQueueTests: XCTestCase {
    /// 非 .ready：send 3 条 → 全部乐观回显（items 3 条 userMessage），但一条 turn/start 都没发出。
    func test_offline_send_enqueues_and_echoes_without_firing() async throws {
        let mock = MockTransport(); let rpc = JSONRPCClient(transport: mock)
        await rpc.start()
        let store = ConversationStore(rpc: rpc, threadId: "t1")
        store.isReady = { false }               // 模拟断线：非 .ready
        await store.startObserving()

        await store.send(input: [.text("a")], model: nil, effort: nil)
        await store.send(input: [.text("b")], model: nil, effort: nil)
        await store.send(input: [.text("c")], model: nil, effort: nil)

        let texts = store.state.items.compactMap { i -> String? in
            if case .userMessage(_, let t) = i { return t } else { return nil }
        }
        XCTAssertEqual(texts, ["a", "b", "c"], "断线期间应乐观回显 3 条")
        // 关键：未 fire turn/start（给足时间让任何 Task 写出帧）
        try await Task.sleep(nanoseconds: 120_000_000)
        let fired = await mock.sent.contains { $0.contains("turn/start") }
        XCTAssertFalse(fired, "断线期间绝不 fire turn/start")
    }

    /// .ready + flush → 按入队序 fire 3 次 turn/start，且不产生重复气泡（仍 3 条 userMessage）。
    func test_flush_fires_in_order_without_duplicate_echo() async throws {
        let mock = MockTransport(); let rpc = JSONRPCClient(transport: mock)
        await mock.setAutoRespond(true)
        await rpc.start()
        let store = ConversationStore(rpc: rpc, threadId: "t1")
        store.isReady = { false }
        await store.startObserving()

        await store.send(input: [.text("a")], model: nil, effort: nil)
        await store.send(input: [.text("b")], model: nil, effort: nil)
        await store.send(input: [.text("c")], model: nil, effort: nil)

        store.isReady = { true }                // 连接恢复
        await store.flushPendingOutbound()

        try await waitUntil { await mock.sent.filter { $0.contains("turn/start") }.count == 3 }
        // 无重复气泡：仍是 3 条 userMessage（补发跳过回显）
        let userMsgs = store.state.items.filter { if case .userMessage = $0 { return true }; return false }
        XCTAssertEqual(userMsgs.count, 3, "补发不得重复回显")
        // 按入队序发出
        let sent = await mock.sent.filter { $0.contains("turn/start") }
        func idx(_ s: String) -> Int? { sent.firstIndex { $0.contains("\"text\":\"\(s)\"") } }
        XCTAssertTrue((idx("a") ?? -1) < (idx("b") ?? -1) && (idx("b") ?? -1) < (idx("c") ?? -1),
                      "补发顺序必须等于入队顺序（FIFO）")
    }

    /// .ready 下 send → 直接 fire（不入队、不需 flush）。
    func test_ready_send_fires_immediately() async throws {
        let mock = MockTransport(); let rpc = JSONRPCClient(transport: mock)
        await mock.setAutoRespond(true)
        await rpc.start()
        let store = ConversationStore(rpc: rpc, threadId: "t1")
        store.isReady = { true }
        await store.startObserving()
        await store.send(input: [.text("hi")], model: nil, effort: nil)
        try await waitUntil { await mock.sent.contains { $0.contains("turn/start") } }
    }

    /// 控制类不入队：interrupt/steer 不经 send，flush 后无多余 turn/start。
    func test_control_paths_do_not_enqueue() async throws {
        let mock = MockTransport(); let rpc = JSONRPCClient(transport: mock)
        await mock.setAutoRespond(true)
        await rpc.start()
        let store = ConversationStore(rpc: rpc, threadId: "t1")
        store.isReady = { false }
        await store.startObserving()

        await store.interrupt()
        _ = await store.steer(input: [.text("x")])   // 无活跃 turn → 不发出
        store.isReady = { true }
        await store.flushPendingOutbound()

        try await Task.sleep(nanoseconds: 100_000_000)
        let fired = await mock.sent.contains { $0.contains("turn/start") }
        XCTAssertFalse(fired, "interrupt/steer 不入离线队列，flush 后无 turn/start")
    }

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
