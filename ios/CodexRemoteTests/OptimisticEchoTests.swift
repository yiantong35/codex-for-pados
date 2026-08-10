import XCTest
@testable import CodexRemote

@MainActor
final class OptimisticEchoTests: XCTestCase {
    /// 发送后本端立即出现 userMessage 气泡（不等服务器广播）。
    func testOptimisticEchoAppearsImmediately() async throws {
        let mock = MockTransport(); let rpc = JSONRPCClient(transport: mock)
        await mock.setAutoRespond(true)
        await rpc.start()
        let store = ConversationStore(rpc: rpc, threadId: "t1")
        await store.startObserving()

        await store.send(input: [.text("hello world")], model: nil, effort: nil)
        let texts = store.state.items.compactMap { item -> String? in
            if case .userMessage(_, let t, _) = item { return t } else { return nil }
        }
        XCTAssertEqual(texts, ["hello world"], "发送后应立即乐观回显一条 userMessage")
    }

    /// 服务器权威 userMessage 到达 → 替换乐观项，不重复。
    func testServerEchoReconcilesOptimistic() async throws {
        let mock = MockTransport(); let rpc = JSONRPCClient(transport: mock)
        await mock.setAutoRespond(true)
        await rpc.start()
        let store = ConversationStore(rpc: rpc, threadId: "t1")
        await store.startObserving()

        await store.send(input: [.text("hello world")], model: nil, effort: nil)
        // 服务器回显同一条（权威 id）
        await mock.feed(#"{"jsonrpc":"2.0","method":"item/started","params":{"threadId":"t1","item":{"id":"srv-1","type":"userMessage","content":[{"type":"text","text":"hello world"}]}}}"#)
        try await waitUntil {
            store.state.items.contains { if case .userMessage(let id, _, _) = $0 { return id == "srv-1" }; return false }
        }
        let userMsgs = store.state.items.filter { if case .userMessage = $0 { return true }; return false }
        XCTAssertEqual(userMsgs.count, 1, "权威回显应替换乐观项，不重复")
        if case .userMessage(let id, _, _)? = userMsgs.first {
            XCTAssertEqual(id, "srv-1", "对账后应以服务器权威 id 为准")
        }
    }

    /// 他端发起（本端无乐观项）→ 正常插入不误删。
    func testForeignUserMessageInsertsNormally() {
        var state = ConversationState(threadId: "t1")
        let reducer = ThreadReducer()
        let item: [String: Any] = ["id": "srv-9", "type": "userMessage",
            "content": [["type": "text", "text": "from desktop"] as [String: Any]]]
        reducer.apply(notif("item/started", ["item": item]), to: &state)
        let userMsgs = state.items.compactMap { i -> String? in
            if case .userMessage(_, let t, _) = i { return t } else { return nil }
        }
        XCTAssertEqual(userMsgs, ["from desktop"], "他端发起的 userMessage 应正常插入")
    }

    func testImageOnlyMessageRemainsVisibleAndReconciles() async throws {
        let mock = MockTransport(); let rpc = JSONRPCClient(transport: mock)
        await mock.setAutoRespond(true)
        await rpc.start()
        let store = ConversationStore(rpc: rpc, threadId: "t1")
        await store.startObserving()
        let imageURL = "data:image/jpeg;base64,AQID"

        await store.send(input: [.image(url: imageURL, detail: .high)], model: nil, effort: nil)
        guard case .userMessage(_, let text, let attachments)? = store.state.items.first else {
            return XCTFail("图片单独发送后应保留用户消息")
        }
        XCTAssertEqual(text, "")
        XCTAssertEqual(attachments, [UserMessageAttachment(kind: .image, source: imageURL)])

        await mock.feed(#"{"jsonrpc":"2.0","method":"item/started","params":{"threadId":"t1","item":{"id":"srv-image","type":"userMessage","content":[{"type":"image","url":"data:image/jpeg;base64,AQID","detail":"high"}]}}}"#)
        try await waitUntil {
            store.state.items.contains {
                if case .userMessage(let id, _, _) = $0 { return id == "srv-image" }
                return false
            }
        }
        XCTAssertEqual(store.state.items.filter { if case .userMessage = $0 { return true }; return false }.count, 1)
    }

    // helpers
    private func notif(_ m: String, _ p: [String: Any]) -> JSONRPCNotification {
        JSONRPCNotification(method: m, params: AnyCodable(p))
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
