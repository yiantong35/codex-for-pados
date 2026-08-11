import XCTest
@testable import CodexRemote

@MainActor
final class ConversationSendTests: XCTestCase {
    /// turn/start 失败（传输中断）→ lastSendError 置位、运行态不为真。
    func testSendFailureSurfacesError() async throws {
        let mock = MockTransport(); let rpc = JSONRPCClient(transport: mock)
        await rpc.start()
        let store = ConversationStore(rpc: rpc, threadId: "t1")
        await store.startObserving()

        await store.send(input: [.text("hi")], model: nil, effort: nil)
        // 等 turn/start 帧真正写出（pending 已登记）再中断，避免 fail 早于 pending 注册的竞态
        try await waitUntil { await mock.sent.contains { $0.contains("turn/start") } }
        // 让 turn/start 请求发出后中断传输，使 pending call 抛错
        await mock.fail(TransportError.channelClosed(reason: "boom"))

        try await waitUntil { store.state.lastSendError != nil }
        XCTAssertNotNil(store.state.lastSendError, "发送失败应置 lastSendError")
        XCTAssertFalse(store.state.lastSendError?.contains("channelClosed") == true)
        XCTAssertFalse(store.state.lastSendError?.contains("boom") == true)
        XCTAssertFalse(store.state.isTurnRunning, "发送失败不应显示生成中")
    }

    /// send 成功 → 无错误。
    func testSendSuccessClearsError() async throws {
        let mock = MockTransport(); let rpc = JSONRPCClient(transport: mock)
        await mock.setAutoRespond(true)
        await rpc.start()
        let store = ConversationStore(rpc: rpc, threadId: "t1")
        await store.startObserving()

        await store.send(input: [.text("hi")], model: nil, effort: nil)
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertNil(store.state.lastSendError, "成功发送不应有错误")
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
