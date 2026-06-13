import XCTest
@testable import CodexRemote

@MainActor
final class ConversationStoreTests: XCTestCase {
    /// 流式 delta 经 ThreadReducer 归约进 ConversationState.items。
    func testStreamingDeltaUpdatesState() async throws {
        let mock = MockTransport()
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()
        let store = ConversationStore(rpc: rpc, threadId: "t1")
        await store.startObserving()

        // 真实嵌套形状：turn/started 的 turn 在 params.turn，item/started 的 item 在 params.item。
        await mock.feed(#"{"jsonrpc":"2.0","method":"turn/started","params":{"threadId":"t1","turn":{"id":"T1","status":"inProgress"}}}"#)
        await mock.feed(#"{"jsonrpc":"2.0","method":"item/started","params":{"threadId":"t1","item":{"id":"I1","type":"agentMessage","text":""}}}"#)
        await mock.feed(#"{"jsonrpc":"2.0","method":"item/agentMessage/delta","params":{"threadId":"t1","itemId":"I1","delta":"Hi"}}"#)

        try await waitUntil { store.state.items.first.flatMap { if case .agentMessage(_, let t) = $0 { return t == "Hi" } else { return false } } ?? false }

        guard case .agentMessage(_, let text)? = store.state.items.first else {
            return XCTFail("expected agentMessage item, got \(store.state.items)")
        }
        XCTAssertEqual(text, "Hi")
        XCTAssertEqual(store.state.activeTurnId, "T1")
    }

    /// 回归（多播订阅注册竞态）：startObserving() 返回后立即 feed（无 sleep），事件必须被捕获。
    /// 旧实现把订阅注册放进游离 Task，startObserving() 同步返回时注册可能尚未完成，
    /// 紧随到达的通知会 yield 给零个订阅者而丢失。修复后 startObserving() 为 async，
    /// 注册先于返回完成，故返回后到达的通知不丢。
    func testStartObservingRegistersBeforeReturn() async throws {
        let mock = MockTransport()
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()
        let store = ConversationStore(rpc: rpc, threadId: "t1")

        await store.startObserving()
        // 紧随其后 feed，不加任何 sleep：订阅若未在 startObserving 返回前注册，此帧会丢失。
        await mock.feed(#"{"jsonrpc":"2.0","method":"turn/started","params":{"threadId":"t1","turn":{"id":"T1","status":"inProgress"}}}"#)

        try await waitUntil { store.state.activeTurnId == "T1" }
        XCTAssertEqual(store.state.activeTurnId, "T1")
    }

    /// send() 发出 turn/start，参数含 effort。
    func testSendPromptIssuesTurnStart() async throws {
        let mock = MockTransport()
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()
        let store = ConversationStore(rpc: rpc, threadId: "t1")

        await store.send(input: [.text("hello")], model: "gpt-5", effort: .high)

        try await waitUntil { await mock.sent.contains { $0.contains("turn/start") } }
        let sent = await mock.sent.last!
        XCTAssertTrue(sent.contains("turn/start"), sent)
        XCTAssertTrue(sent.contains(#""effort":"high""#), sent)
        XCTAssertTrue(sent.contains(#""threadId":"t1""#), sent)
    }

    /// resume() 发出 thread/resume。
    func testResumeIssuesThreadResume() async throws {
        let mock = MockTransport()
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()
        let store = ConversationStore(rpc: rpc, threadId: "t1")

        await store.resume()

        try await waitUntil { await mock.sent.contains { $0.contains("thread/resume") } }
        let sent = await mock.sent.first { $0.contains("thread/resume") }!
        XCTAssertTrue(sent.contains(#""threadId":"t1""#), sent)
    }

    /// resume() 必须捕获响应并把历史 turn/item 灌入 state（修复「恢复桌面会话看不到历史」）。
    func testResumeIngestsHistoryFromResponse() async throws {
        let mock = MockTransport()
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()
        let store = ConversationStore(rpc: rpc, threadId: "t1")

        await store.resume()
        // 等 resume 请求发出（拿到将被匹配的 id=1）。
        try await waitUntil { await mock.sent.contains { $0.contains("thread/resume") } }

        // 模拟服务端用带历史的 result 响应 id=1。
        let response = #"{"jsonrpc":"2.0","id":1,"result":{"thread":{"id":"t1","turns":[{"id":"turn-1","items":[{"type":"userMessage","id":"u1","content":[{"type":"text","text":"历史问题","text_elements":[]}]},{"type":"agentMessage","id":"a1","text":"历史回答"}]}]}}}"#
        await mock.feed(response)

        try await waitUntil {
            store.state.items.contains { if case .agentMessage(_, let t) = $0 { return t == "历史回答" } else { return false } }
        }
        XCTAssertTrue(store.state.items.contains { if case .userMessage(_, let t) = $0 { return t == "历史问题" } else { return false } },
                      "resume 历史 userMessage 应进入 state，实际：\(store.state.items)")
    }

    // MARK: - helpers

    /// 轮询条件直到为真或超时，避免固定 sleep 造成 flake。
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
