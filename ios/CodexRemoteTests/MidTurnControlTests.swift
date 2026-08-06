import XCTest
@testable import CodexRemote

@MainActor
final class MidTurnControlTests: XCTestCase {
    /// 构造一个 turn 进行中的 store（activeTurnId=T1）。
    private func runningStore() async -> (ConversationStore, MockTransport) {
        let mock = MockTransport(); let rpc = JSONRPCClient(transport: mock)
        await rpc.start()
        let store = ConversationStore(rpc: rpc, threadId: "t1")
        await store.startObserving()
        await mock.feed(#"{"jsonrpc":"2.0","method":"turn/started","params":{"threadId":"t1","turn":{"id":"T1","status":"inProgress"}}}"#)
        try? await Task.sleep(nanoseconds: 50_000_000)
        return (store, mock)
    }

    /// steer：turn 进行中 → 发 turn/steer，带 expectedTurnId=T1。
    func testSteerSendsExpectedTurnId() async throws {
        let (store, mock) = await runningStore()
        let responder = respondToSteer(mock, error: nil)
        let ok = await store.steer(input: [.text("change course")])
        responder.cancel()
        XCTAssertTrue(ok)
        try await waitUntil { await mock.sent.contains { $0.contains("turn/steer") } }
        let sent = await mock.sent.first { $0.contains("turn/steer") }!
        XCTAssertTrue(sent.contains(#""expectedTurnId":"T1""#), sent)
        XCTAssertTrue(sent.contains(#""threadId":"t1""#), sent)
    }

    func testSteerReturnsFalseWhenServerRejects() async throws {
        let (store, mock) = await runningStore()
        let responder = respondToSteer(mock, error: "rejected")
        let ok = await store.steer(input: [.text("do not discard me")])
        responder.cancel()
        XCTAssertFalse(ok)
    }

    /// review 类型 turn 不可 steer：steer 返回 false 且不发帧。
    func testSteerBlockedForReviewTurn() async throws {
        let (store, mock) = await runningStore()
        await mock.feed(#"{"jsonrpc":"2.0","method":"turn/started","params":{"threadId":"t1","turn":{"id":"T2","kind":"review","status":"inProgress"}}}"#)
        try await waitUntil { store.state.activeTurnKind == .review }
        let before = await mock.sent.count
        let ok = await store.steer(input: [.text("x")])
        XCTAssertFalse(ok)
        let after = await mock.sent.count
        XCTAssertEqual(after, before)
    }

    /// turn 空闲时 steer 也应失败（无 activeTurnId）。
    func testSteerBlockedWhenIdle() async throws {
        let mock = MockTransport(); let rpc = JSONRPCClient(transport: mock)
        await rpc.start()
        let store = ConversationStore(rpc: rpc, threadId: "t1")
        await store.startObserving()
        let ok = await store.steer(input: [.text("x")])
        XCTAssertFalse(ok)
    }

    /// 排队：turn 进行中 enqueue 仅暂存，不立即发 turn/start（drain 被 isTurnRunning 挡住）。
    func testEnqueueBuffersWhenRunning() async throws {
        let (store, mock) = await runningStore()
        await store.enqueue(input: [.text("later")])
        XCTAssertEqual(store.outbox.count, 1)
        // 没有新的 turn/start（注意排除 turn/started 通知，那是服务端帧不是 sent）
        let hasTurnStart = await mock.sent.contains { $0.contains("turn/start") }
        XCTAssertFalse(hasTurnStart)
    }

    /// 排队后收到 turn/completed → 自动出队发 turn/start。
    func testEnqueueDrainsOnTurnCompleted() async throws {
        let (store, mock) = await runningStore()
        await store.enqueue(input: [.text("later")])
        await mock.feed(#"{"jsonrpc":"2.0","method":"turn/completed","params":{"threadId":"t1"}}"#)
        try await waitUntil { await mock.sent.contains { $0.contains("turn/start") } }
        XCTAssertTrue(store.outbox.isEmpty)
    }

    /// interrupt：发 turn/interrupt + threadId。
    func testInterruptSends() async throws {
        let (store, mock) = await runningStore()
        await store.interrupt()
        try await waitUntil { await mock.sent.contains { $0.contains("turn/interrupt") } }
        let sent = await mock.sent.first { $0.contains("turn/interrupt") }!
        XCTAssertTrue(sent.contains(#""threadId":"t1""#), sent)
    }

    // MARK: - helpers

    private func waitUntil(timeout: TimeInterval = 2.0,
                           _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("waitUntil timed out")
    }

    private func respondToSteer(_ mock: MockTransport, error: String?) -> Task<Void, Never> {
        Task {
            for _ in 0..<200 {
                for frame in await mock.sent where frame.contains(#""method":"turn/steer""#) {
                    guard let object = try? JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any],
                          let id = object["id"] as? String else { continue }
                    if let error {
                        await mock.feed(#"{"id":"\#(id)","error":{"code":-32000,"message":"\#(error)"}}"#)
                    } else {
                        await mock.feed(#"{"id":"\#(id)","result":{}}"#)
                    }
                    return
                }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
    }
}
