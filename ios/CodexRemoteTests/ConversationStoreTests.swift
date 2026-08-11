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
        await mock.setAutoRespond(true)
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()
        let store = ConversationStore(rpc: rpc, threadId: "t1")

        await store.resume()

        try await waitUntil { await mock.sent.contains { $0.contains("thread/resume") } }
        let sent = await mock.sent.first { $0.contains("thread/resume") }!
        XCTAssertTrue(sent.contains(#""threadId":"t1""#), sent)
        XCTAssertEqual(store.loadState, .loaded)
    }

    /// resume() 必须捕获响应并把历史 turn/item 灌入 state（修复「恢复桌面会话看不到历史」）。
    func testResumeIngestsHistoryFromResponse() async throws {
        let mock = MockTransport()
        await mock.setAutoRespond(true)
        await mock.setThreadResumeResponse(#"{"thread":{"id":"t1","turns":[{"id":"turn-1","items":[{"type":"userMessage","id":"u1","content":[{"type":"text","text":"历史问题","text_elements":[]}]},{"type":"agentMessage","id":"a1","text":"历史回答"}]}]}}"#)
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()
        let store = ConversationStore(rpc: rpc, threadId: "t1")

        await store.resume()
        XCTAssertEqual(store.loadState, .loaded)
        XCTAssertTrue(store.state.items.contains { if case .userMessage(_, let t, _) = $0 { return t == "历史问题" } else { return false } },
                      "resume 历史 userMessage 应进入 state，实际：\(store.state.items)")
        XCTAssertTrue(store.state.items.contains { if case .agentMessage(_, let t) = $0 { return t == "历史回答" } else { return false } })
    }

    func testResumeTreatsNoRolloutAsLoadedEmptyThread() async throws {
        let mock = MockTransport()
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()
        let store = ConversationStore(rpc: rpc, threadId: "new-thread")

        let resume = Task { await store.resume() }
        try await waitUntil { await mock.sent.contains { $0.contains(RPCMethod.threadResume) } }
        let sent = await mock.sent
        let frame = try XCTUnwrap(sent.first { $0.contains(RPCMethod.threadResume) })
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any]
        )
        let id = try XCTUnwrap(object["id"] as? String)
        await mock.feed(#"{"id":"\#(id)","error":{"code":-32600,"message":"no rollout found for thread id new-thread"}}"#)
        await resume.value

        XCTAssertEqual(store.loadState, .loaded)
        XCTAssertFalse(store.state.isTurnRunning)
    }

    func testAuthoritativeSnapshotRemovesItemsMissingAfterRollback() {
        let mock = MockTransport()
        let rpc = JSONRPCClient(transport: mock)
        let store = ConversationStore(rpc: rpc, threadId: "t1")
        store.applyAuthoritativeThreadSnapshot([
            "thread": ["id": "t1", "turns": [[
                "id": "turn-1", "status": "completed", "items": [
                    ["id": "kept", "type": "agentMessage", "text": "keep"],
                    ["id": "removed", "type": "agentMessage", "text": "remove"],
                ],
            ]]],
        ])
        store.applyAuthoritativeThreadSnapshot([
            "thread": ["id": "t1", "turns": [[
                "id": "turn-1", "status": "completed", "items": [
                    ["id": "kept", "type": "agentMessage", "text": "keep"],
                ],
            ]]],
        ])

        XCTAssertEqual(store.state.items.map(\.id), ["kept"])
    }

    func testResumeFailureIsVisibleAndRetryable() async throws {
        let mock = MockTransport()
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()
        let store = ConversationStore(rpc: rpc, threadId: "t1")

        let resume = Task { await store.resume() }
        try await waitUntil { await mock.sent.contains { $0.contains("thread/resume") } }
        await mock.fail(MockTransportError.scriptedFailure)
        await resume.value

        XCTAssertEqual(store.loadState, .failed)
    }

    // MARK: - §5 可见会话恢复：仅恢复当前 thread

    func testCurrentThreadRecoveryDoesNotListOrResumeOtherThreads() async throws {
        let mock = MockTransport()
        await mock.setAutoRespond(true)
        await mock.setThreadResumeResponse(#"{"thread":{"id":"thread-running-1","turns":[]}}"#)
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()
        let store = ConversationStore(rpc: rpc, threadId: "thread-running-1")

        await store.recoverCurrentThread()

        let sent = await mock.sent
        XCTAssertFalse(sent.contains { $0.contains("thread/loaded/list") },
                       "视图级恢复不得重复拉取全部 running threads")
        let resumeReq = sent.first { $0.contains("thread/resume") }!
        XCTAssertTrue(resumeReq.contains(#""threadId":"thread-running-1""#), resumeReq)
    }

    func testCurrentThreadRecoveryTreatsNoRolloutAsAuthoritativeIdle() async throws {
        let mock = MockTransport()
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()
        let store = ConversationStore(rpc: rpc, threadId: "new-thread")
        let responder = Task { await Self.replyToRejoin(mock, loadedIds: [], noRolloutIds: ["new-thread"]) }

        await store.recoverCurrentThread()
        responder.cancel()

        XCTAssertEqual(store.loadState, .loaded)
        XCTAssertFalse(store.state.isTurnRunning)
    }

    /// item 2 现状锁定（Design §3.3）：当前 thread 权威恢复时，
    /// 真正把 thread/resume 响应里携带的历史 item（turns[].items[]）ingest 进 state ——
    /// 不是只订阅不摄入的空转。响应构造复用 testResumeIngestsHistoryFromResponse 已验证的
    /// 真实 schema（userMessage: content[].text；agentMessage: 顶层 text），不新造协议形状。
    /// 断言真实历史文本而非仅 threadId 不变：防止未来把 rejoin 退化为「重连但不刷新正文」。
    func test_rejoin_ingests_history_for_current_thread() async throws {
        let mock = MockTransport()
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()
        let store = ConversationStore(rpc: rpc, threadId: "t1")
        await store.startObserving()

        // 后台模拟服务端：thread/loaded/list 回 {data:["t1"]}；对 t1 的 thread/resume 回带历史 turn 的响应。
        let responder = Task { await Self.replyToRejoinWithHistory(mock, threadId: "t1") }

        await store.recoverCurrentThread()
        responder.cancel()

        XCTAssertTrue(store.state.items.contains {
            if case .userMessage(_, let t, _) = $0 { return t == "历史问题" } else { return false }
        }, "rejoin 命中当前 thread 应 ingest 历史 userMessage，实际：\(store.state.items)")
        XCTAssertTrue(store.state.items.contains {
            if case .agentMessage(_, let t) = $0 { return t == "历史回答" } else { return false }
        }, "rejoin 命中当前 thread 应 ingest 历史 agentMessage，实际：\(store.state.items)")
    }

    /// 测试用模拟服务端：轮询 mock.sent，对 thread/loaded/list 回 {data:[threadId]}，
    /// 对命中 threadId 的 thread/resume 回携带历史 turns 的响应（真实 schema，同上）。
    private static func replyToRejoinWithHistory(_ mock: MockTransport, threadId: String) async {
        var answeredList = false
        var answeredResume = false
        for _ in 0..<400 {
            if Task.isCancelled { return }
            let sent = await mock.sent
            for frame in sent {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any],
                      let id = obj["id"] as? String,
                      let method = obj["method"] as? String else { continue }
                if method == "thread/loaded/list", !answeredList {
                    answeredList = true
                    await mock.feed(#"{"jsonrpc":"2.0","id":"\#(id)","result":{"data":["\#(threadId)"],"nextCursor":null}}"#)
                } else if method == "thread/resume", !answeredResume {
                    let tid = (obj["params"] as? [String: Any])?["threadId"] as? String ?? ""
                    guard tid == threadId else { continue }
                    answeredResume = true
                    let response = #"{"jsonrpc":"2.0","id":"\#(id)","result":{"thread":{"id":"\#(tid)","turns":[{"id":"turn-1","items":[{"type":"userMessage","id":"u1","content":[{"type":"text","text":"历史问题","text_elements":[]}]},{"type":"agentMessage","id":"a1","text":"历史回答"}]}]}}}"#
                    await mock.feed(response)
                }
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
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

    // MARK: - fix-lifecycle-energy-leaks D2：切对话不累积正文订阅

    func testSwitchingThreadsKeepsSingleLiveSubscriber() async throws {
        let mock = MockTransport()
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()

        // 反例：只建不停 → 订阅累积（证明泄漏路径真实存在）。
        var leaked: [ConversationStore] = []
        for i in 0..<4 {
            let s = ConversationStore(rpc: rpc, threadId: "leak-\(i)")
            await s.startObserving()
            leaked.append(s)
        }
        let grew = try await waitUntilCount(rpc, is: 4)
        XCTAssertTrue(grew, "不停旧订阅时 notifications 订阅应累积到 4（泄漏特征）")
        for s in leaked { s.stopObserving() }
        _ = try await waitUntilCount(rpc, is: 0)

        // 正例（D2 修复后 ConversationView 的行为）：切走前停旧、再建新 → 恒 1。
        var current: ConversationStore?
        for i in 0..<5 {
            current?.stopObserving()
            let s = ConversationStore(rpc: rpc, threadId: "t-\(i)")
            await s.startObserving()
            current = s
            let ok = try await waitUntilCount(rpc, is: 1)
            XCTAssertTrue(ok, "第 \(i) 次切换后存活订阅数应恒为 1")
        }
    }

    private func waitUntilCount(_ rpc: JSONRPCClient, is expected: Int,
                               timeout: TimeInterval = 2.0) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await rpc.liveNotificationSubscriberCount() == expected { return true }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return await rpc.liveNotificationSubscriberCount() == expected
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
