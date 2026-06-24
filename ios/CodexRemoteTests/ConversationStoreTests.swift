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
        // 等 resume 请求发出，并解出其实际 id（Task 6 起 id 为 ipad-<UUID>，不再是整型 1）。
        try await waitUntil { await mock.sent.contains { $0.contains("thread/resume") } }
        let resumeReq = await mock.sent.first { $0.contains("thread/resume") }!
        let reqObj = try JSONSerialization.jsonObject(with: Data(resumeReq.utf8)) as! [String: Any]
        let resumeId = reqObj["id"] as! String

        // 模拟服务端用带历史的 result 响应该 id。
        let response = #"{"jsonrpc":"2.0","id":"\#(resumeId)","result":{"thread":{"id":"t1","turns":[{"id":"turn-1","items":[{"type":"userMessage","id":"u1","content":[{"type":"text","text":"历史问题","text_elements":[]}]},{"type":"agentMessage","id":"a1","text":"历史回答"}]}]}}}"#
        await mock.feed(response)

        try await waitUntil {
            store.state.items.contains { if case .agentMessage(_, let t) = $0 { return t == "历史回答" } else { return false } }
        }
        XCTAssertTrue(store.state.items.contains { if case .userMessage(_, let t) = $0 { return t == "历史问题" } else { return false } },
                      "resume 历史 userMessage 应进入 state，实际：\(store.state.items)")
    }

    // MARK: - §5 重连恢复：thread/loaded/list + thread/resume(rejoin)

    /// 重连恢复：先发 thread/loaded/list，对返回的每个 running thread 发 thread/resume（rejoin + 自动订阅）。
    func testRejoinCallsLoadedListThenResume() async throws {
        let mock = MockTransport()
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()
        let store = ConversationStore(rpc: rpc, threadId: "thread-running-1")

        // 后台模拟服务端：对 thread/loaded/list 回 {data:["thread-running-1"]}，对 thread/resume 回历史。
        let responder = Task { await Self.replyToRejoin(mock, loadedIds: ["thread-running-1"]) }

        await store.rejoinRunningThreads()
        responder.cancel()

        let sent = await mock.sent
        // 先 loaded/list，再 resume
        let listIdx = sent.firstIndex { $0.contains("thread/loaded/list") }
        let resumeIdx = sent.firstIndex { $0.contains("thread/resume") }
        XCTAssertNotNil(listIdx, "应发出 thread/loaded/list；实际：\(sent)")
        XCTAssertNotNil(resumeIdx, "应发出 thread/resume；实际：\(sent)")
        if let l = listIdx, let r = resumeIdx { XCTAssertLessThan(l, r, "loaded/list 应先于 resume") }
        let resumeReq = sent.first { $0.contains("thread/resume") }!
        XCTAssertTrue(resumeReq.contains(#""threadId":"thread-running-1""#), resumeReq)
    }

    /// no-rollout 容忍：某 thread 的 thread/resume 返回 -32600 no rollout found 时跳过，
    /// 继续对其余 thread resume，不整批失败。
    func testRejoinSkipsNoRolloutAndContinues() async throws {
        let mock = MockTransport()
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()
        let store = ConversationStore(rpc: rpc, threadId: "t-good")

        // loaded/list 返回两个 id：t-bad（no rollout）→ t-good（成功）。
        let responder = Task {
            await Self.replyToRejoin(mock, loadedIds: ["t-bad", "t-good"],
                                     noRolloutIds: ["t-bad"])
        }

        await store.rejoinRunningThreads()
        responder.cancel()

        let sent = await mock.sent
        // 两个 thread 都被 resume（单个失败未中断整批）
        XCTAssertTrue(sent.contains { $0.contains("thread/resume") && $0.contains(#""threadId":"t-bad""#) },
                      "应对 t-bad 发出 resume；实际：\(sent)")
        XCTAssertTrue(sent.contains { $0.contains("thread/resume") && $0.contains(#""threadId":"t-good""#) },
                      "no-rollout 失败后应继续对 t-good resume；实际：\(sent)")
    }

    /// 不依赖本地 threadId 作唯一恢复依据：state.threadId 为空时仍调 loaded/list 并对返回的 thread resume。
    func testRejoinWorksWithEmptyLocalThreadId() async throws {
        let mock = MockTransport()
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()
        let store = ConversationStore(rpc: rpc, threadId: "")   // 本地无 thread

        let responder = Task { await Self.replyToRejoin(mock, loadedIds: ["thread-x"]) }

        await store.rejoinRunningThreads()
        responder.cancel()

        let sent = await mock.sent
        XCTAssertTrue(sent.contains { $0.contains("thread/loaded/list") },
                      "本地无 threadId 时仍应调 loaded/list；实际：\(sent)")
        XCTAssertTrue(sent.contains { $0.contains("thread/resume") && $0.contains(#""threadId":"thread-x""#) },
                      "应对列表返回的 thread-x resume；实际：\(sent)")
    }

    /// 测试用模拟服务端：轮询 mock.sent，对 thread/loaded/list 回注入的 ids，
    /// 对每个 thread/resume 按 id 回响应（noRolloutIds 中的 thread 回 -32600 no rollout found）。
    private static func replyToRejoin(_ mock: MockTransport,
                                      loadedIds: [String],
                                      noRolloutIds: Set<String> = []) async {
        var answeredList = false
        var answeredResume = Set<String>()
        for _ in 0..<400 {
            if Task.isCancelled { return }
            let sent = await mock.sent
            for frame in sent {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any],
                      let id = obj["id"] as? String,
                      let method = obj["method"] as? String else { continue }
                if method == "thread/loaded/list", !answeredList {
                    answeredList = true
                    let arr = loadedIds.map { "\"\($0)\"" }.joined(separator: ",")
                    await mock.feed(#"{"jsonrpc":"2.0","id":"\#(id)","result":{"data":[\#(arr)],"nextCursor":null}}"#)
                } else if method == "thread/resume" {
                    let tid = (obj["params"] as? [String: Any])?["threadId"] as? String ?? ""
                    let key = "\(id)|\(tid)"
                    if answeredResume.contains(key) { continue }
                    answeredResume.insert(key)
                    if noRolloutIds.contains(tid) {
                        await mock.feed(#"{"jsonrpc":"2.0","id":"\#(id)","error":{"code":-32600,"message":"no rollout found for thread id \#(tid)"}}"#)
                    } else {
                        await mock.feed(#"{"jsonrpc":"2.0","id":"\#(id)","result":{"thread":{"id":"\#(tid)","turns":[]}}}"#)
                    }
                }
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
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
