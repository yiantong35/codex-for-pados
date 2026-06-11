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
        store.startObserving()

        await mock.feed(#"{"jsonrpc":"2.0","method":"turn/started","params":{"turnId":"T1"}}"#)
        await mock.feed(#"{"jsonrpc":"2.0","method":"item/started","params":{"itemId":"I1","itemType":"agentMessage"}}"#)
        await mock.feed(#"{"jsonrpc":"2.0","method":"item/agentMessage/delta","params":{"itemId":"I1","delta":"Hi"}}"#)

        try await waitUntil { store.state.items.first.flatMap { if case .agentMessage(_, let t) = $0 { return t == "Hi" } else { return false } } ?? false }

        guard case .agentMessage(_, let text)? = store.state.items.first else {
            return XCTFail("expected agentMessage item, got \(store.state.items)")
        }
        XCTAssertEqual(text, "Hi")
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
