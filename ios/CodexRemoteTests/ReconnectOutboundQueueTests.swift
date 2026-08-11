import XCTest
@testable import CodexRemote

@MainActor
final class ReconnectOutboundQueueTests: XCTestCase {
    func test_ready_does_not_drain_before_authoritative_resume() async throws {
        let mock = MockTransport()
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()
        let store = ConversationStore(rpc: rpc, threadId: "t1")
        store.isReady = { false }
        await store.send(input: [.text("queued")], model: nil, effort: nil)

        store.requireAuthoritativeRecovery()
        store.isReady = { true }
        store.drainOutbox()
        var sent = await mock.sent
        XCTAssertFalse(sent.contains { $0.contains(RPCMethod.turnStart) })

        let responder = replyToRecovery(
            mock,
            currentThreadId: "t1",
            resumeResult: #"{"thread":{"id":"t1","turns":[{"id":"remote","status":"inProgress","items":[]}]}}"#
        )
        await store.recoverCurrentThread()
        responder.cancel()

        XCTAssertTrue(store.state.isTurnRunning)
        sent = await mock.sent
        XCTAssertFalse(sent.contains { $0.contains(RPCMethod.turnStart) },
                       "queued input must remain blocked while the authoritative turn is running")
    }

    func test_no_rollout_is_authoritative_idle_and_releases_first_message() async throws {
        let mock = MockTransport()
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()
        let store = ConversationStore(rpc: rpc, threadId: "new-thread")
        store.isReady = { false }
        await store.send(input: [.text("first")], model: nil, effort: nil)
        store.isReady = { true }

        let responder = replyToRecovery(mock, currentThreadId: "new-thread", noRollout: true)
        await store.recoverCurrentThread()
        responder.cancel()

        try await waitUntil { await mock.sent.filter { $0.contains(RPCMethod.turnStart) }.count == 1 }
    }

    func test_overlapping_recovery_generations_send_queue_head_once() async throws {
        let mock = MockTransport()
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()
        let store = ConversationStore(rpc: rpc, threadId: "t1")
        store.isReady = { false }
        await store.send(input: [.text("once")], model: nil, effort: nil)
        store.isReady = { true }

        let responder = replyToRecovery(
            mock,
            currentThreadId: "t1",
            resumeResult: #"{"thread":{"id":"t1","turns":[{"id":"done","status":"completed","items":[]}]}}"#
        )
        async let first: Void = store.recoverCurrentThread()
        async let second: Void = store.recoverCurrentThread()
        _ = await (first, second)
        responder.cancel()

        try await waitUntil { await mock.sent.contains { $0.contains(RPCMethod.turnStart) } }
        try await Task.sleep(nanoseconds: 80_000_000)
        let sent = await mock.sent
        XCTAssertEqual(sent.filter { $0.contains(RPCMethod.turnStart) }.count, 1)
    }

    func test_unrelatedTurnEventsDoNotAcknowledgeLocalSend() async throws {
        let shared = ConversationOutbox()
        let mock = MockTransport()
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()
        let store = ConversationStore(rpc: rpc, threadId: "t1", outbox: shared)
        store.isReady = { true }
        await store.startObserving()

        await store.send(input: [.text("local pending")], model: nil, effort: nil)
        try await waitUntil { await mock.sent.contains { $0.contains("turn/start") } }
        await mock.feed(#"{"jsonrpc":"2.0","method":"turn/started","params":{"threadId":"t1","turn":{"id":"other","status":"inProgress"}}}"#)
        await mock.feed(#"{"jsonrpc":"2.0","method":"turn/completed","params":{"threadId":"t1","turn":{"id":"other","status":"completed"}}}"#)
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(shared.entries.count, 1)
        guard case .text(let text)? = shared.entries.first?.input.first else {
            return XCTFail("the local pending message must remain in the outbox")
        }
        XCTAssertEqual(text, "local pending")
    }

    func test_messageTooLargeIsDiscardedAndDoesNotBlockNextEntry() async throws {
        let shared = ConversationOutbox()
        let mock = MockTransport()
        await mock.setAutoRespond(true)
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()
        let store = ConversationStore(rpc: rpc, threadId: "t1", outbox: shared)
        store.isReady = { false }

        await store.send(input: [.text("too large")], model: nil, effort: nil)
        await store.send(input: [.text("following")], model: nil, effort: nil)
        await mock.failNextSend(with: .messageTooLarge(bytes: 101, limit: 100))
        store.isReady = { true }
        store.drainOutbox()

        try await waitUntil { await mock.sent.filter { $0.contains("turn/start") }.count == 2 }
        try await waitUntil { shared.entries.isEmpty }
        let texts = store.state.items.compactMap { item -> String? in
            if case .userMessage(_, let text, _) = item { return text }
            return nil
        }
        XCTAssertEqual(texts, ["following"])
        XCTAssertFalse(store.lastSendErrorIsRetryable)
    }

    func test_outboxEnforcesThreadAndSessionBudgetsAndReleasesOnRemoval() throws {
        let limits = ConversationOutboxLimits(
            maxBytesPerMessage: 10_000,
            maxMessagesPerThread: 2,
            maxBytesPerThread: 10_000,
            maxMessagesPerSession: 2,
            maxBytesPerSession: 10_000
        )
        let registry = ConversationOutboxRegistry(limits: limits)
        let first = registry.outbox(for: "a")
        let second = registry.outbox(for: "b")
        _ = try first.enqueue(input: [.text("one")], model: nil, effort: nil)
        _ = try second.enqueue(input: [.text("two")], model: nil, effort: nil)
        XCTAssertThrowsError(try first.enqueue(input: [.text("three")], model: nil, effort: nil)) {
            XCTAssertEqual($0 as? ConversationOutboxError, .sessionLimit)
        }

        registry.remove(threadId: "b")
        XCTAssertNoThrow(try first.enqueue(input: [.text("three")], model: nil, effort: nil))
        XCTAssertThrowsError(try first.enqueue(input: [.text("four")], model: nil, effort: nil)) {
            XCTAssertEqual($0 as? ConversationOutboxError, .threadLimit)
        }
    }

    func test_oversizedMessageIsRejectedBeforeItCanEnterTheQueue() throws {
        let outbox = ConversationOutbox()
        let oversized = String(repeating: "x", count: 741 * 1_024)

        XCTAssertThrowsError(try outbox.enqueue(input: [.text(oversized)], model: nil, effort: nil)) {
            XCTAssertEqual($0 as? ConversationOutboxError, .messageTooLarge)
        }
        XCTAssertTrue(outbox.entries.isEmpty)
    }

    func test_outbox_survives_store_and_rpc_rebuild() async throws {
        let shared = ConversationOutbox()
        let firstMock = MockTransport()
        let firstRPC = JSONRPCClient(transport: firstMock)
        await firstRPC.start()
        let first = ConversationStore(rpc: firstRPC, threadId: "t1", outbox: shared)
        first.isReady = { false }

        await first.send(input: [.text("survive")], model: "gpt-5", effort: .high)
        let clientId = try XCTUnwrap(first.outbox.first?.clientId)

        let secondMock = MockTransport()
        await secondMock.setAutoRespond(true)
        let secondRPC = JSONRPCClient(transport: secondMock)
        await secondRPC.start()
        let rebuilt = ConversationStore(rpc: secondRPC, threadId: "t1", outbox: shared)
        rebuilt.isReady = { true }

        XCTAssertTrue(rebuilt.state.items.contains { $0.id == "local-\(clientId)" })
        rebuilt.drainOutbox()
        try await waitUntil { await secondMock.sent.contains { $0.contains("turn/start") } }
        let sent = await secondMock.sent
        let request = try XCTUnwrap(sent.first { $0.contains("turn/start") })
        XCTAssertTrue(request.contains(#""clientUserMessageId":"\#(clientId)""#))
    }

    func test_authoritative_resume_releases_missing_turnStarted_window() async throws {
        let mock = MockTransport()
        await mock.setAutoRespond(true)
        await mock.setLoadedThreadListResponse(#"{"data":["t1"],"nextCursor":null}"#)
        await mock.setThreadResumeResponse(#"{"thread":{"id":"t1","turns":[{"id":"done","status":"completed","items":[]}]}}"#)
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()
        let store = ConversationStore(rpc: rpc, threadId: "t1")
        store.isReady = { true }

        await store.send(input: [.text("accepted-before-drop")], model: nil, effort: nil)
        try await waitUntil { await mock.sent.filter { $0.contains("turn/start") }.count == 1 }
        await store.send(input: [.text("queued-after-drop")], model: nil, effort: nil)
        try await Task.sleep(nanoseconds: 80_000_000)
        let beforeResumeCount = await mock.sent.filter { $0.contains("turn/start") }.count
        XCTAssertEqual(beforeResumeCount, 1,
                       "RPC success alone must not open the next send window")

        await store.recoverCurrentThread()
        try await waitUntil { await mock.sent.filter { $0.contains("turn/start") }.count == 2 }
    }

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
            if case .userMessage(_, let t, _) = i { return t } else { return nil }
        }
        XCTAssertEqual(texts, ["a", "b", "c"], "断线期间应乐观回显 3 条")
        // 关键：未 fire turn/start（给足时间让任何 Task 写出帧）
        try await Task.sleep(nanoseconds: 120_000_000)
        let fired = await mock.sent.contains { $0.contains("turn/start") }
        XCTAssertFalse(fired, "断线期间绝不 fire turn/start")
    }

    /// 重连后 outbox 串行逐条 drain：一条 fire → 等 turn/started+turn/completed → 才发下一条，
    /// 绝不并发一次性 fire 多条（终审 #1：合并两队列为单一 outbox 后的核心不变式）。
    func test_reconnect_drains_serially_in_order() async throws {
        let mock = MockTransport(); let rpc = JSONRPCClient(transport: mock)
        await mock.setAutoRespond(true)
        await rpc.start()
        let store = ConversationStore(rpc: rpc, threadId: "t1")
        store.isReady = { false }
        await store.startObserving()

        await store.send(input: [.text("a")], model: nil, effort: nil)
        await store.send(input: [.text("b")], model: nil, effort: nil)
        await store.send(input: [.text("c")], model: nil, effort: nil)
        XCTAssertEqual(store.outbox.count, 3, "断线期间三条都应停在 outbox")
        var fired = await mock.sent.filter { $0.contains("turn/start") }.count
        XCTAssertEqual(fired, 0, "断线期间不应 fire")

        store.isReady = { true }                // 连接恢复
        store.drainOutbox()

        // 只 fire 了第 1 条（a），且短暂等待后仍只有 1 条——证明未并发一次性 fire 多条。
        try await waitUntil { await mock.sent.filter { $0.contains("turn/start") }.count == 1 }
        try await Task.sleep(nanoseconds: 120_000_000)
        fired = await mock.sent.filter { $0.contains("turn/start") }.count
        XCTAssertEqual(fired, 1, "drain 一次只应 fire 一条，未收到 turn/started 前不得发下一条")

        // 喂 a 的 turn/started + turn/completed → 应 drain 出第 2 条（b）。
        await mock.feed(#"{"jsonrpc":"2.0","method":"turn/started","params":{"threadId":"t1","turn":{"id":"Ta","status":"inProgress"}}}"#)
        await mock.feed(#"{"jsonrpc":"2.0","method":"turn/completed","params":{"threadId":"t1"}}"#)
        try await waitUntil { await mock.sent.filter { $0.contains("turn/start") }.count == 2 }

        // 喂 b 的 turn/started + turn/completed → 应 drain 出第 3 条（c）。
        await mock.feed(#"{"jsonrpc":"2.0","method":"turn/started","params":{"threadId":"t1","turn":{"id":"Tb","status":"inProgress"}}}"#)
        await mock.feed(#"{"jsonrpc":"2.0","method":"turn/completed","params":{"threadId":"t1"}}"#)
        try await waitUntil { await mock.sent.filter { $0.contains("turn/start") }.count == 3 }

        // 无重复气泡：仍是 3 条 userMessage（drain 补发不再回显）
        let userMsgs = store.state.items.filter { if case .userMessage = $0 { return true }; return false }
        XCTAssertEqual(userMsgs.count, 3, "补发不得重复回显")
        // 按入队序发出
        let sent = await mock.sent.filter { $0.contains("turn/start") }
        func idx(_ s: String) -> Int? { sent.firstIndex { $0.contains("\"text\":\"\(s)\"") } }
        XCTAssertTrue((idx("a") ?? -1) < (idx("b") ?? -1) && (idx("b") ?? -1) < (idx("c") ?? -1),
                      "补发顺序必须等于入队顺序（FIFO）")
    }

    /// .ready 下 send → 直接 fire（不入队、不需 drain）。
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

    /// 控制类不入队：interrupt/steer 不经 send，drain 后无多余 turn/start。
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
        store.drainOutbox()

        try await Task.sleep(nanoseconds: 100_000_000)
        let fired = await mock.sent.contains { $0.contains("turn/start") }
        XCTAssertFalse(fired, "interrupt/steer 不入离线队列，drain 后无 turn/start")
    }

    /// #2 修复：离线状态下失败重发（retryLastSend）不得二次回显、不得二次入队——
    /// 失败项已原样留在 outbox 头且已回显，retryLastSend 只是再 drain 一次。
    func test_retry_offline_does_not_duplicate_echo() async throws {
        let mock = MockTransport(); let rpc = JSONRPCClient(transport: mock)
        await rpc.start()
        let store = ConversationStore(rpc: rpc, threadId: "t1")
        store.isReady = { false }
        await store.startObserving()

        await store.send(input: [.text("a")], model: nil, effort: nil)
        var userMsgs = store.state.items.filter { if case .userMessage = $0 { return true }; return false }
        XCTAssertEqual(userMsgs.count, 1)
        XCTAssertEqual(store.outbox.count, 1)

        await store.retryLastSend()   // 仍 offline

        userMsgs = store.state.items.filter { if case .userMessage = $0 { return true }; return false }
        XCTAssertEqual(userMsgs.count, 1, "重发不得二次回显")
        XCTAssertEqual(store.outbox.count, 1, "重发不得二次入队")
    }

    func test_failed_head_can_be_discarded_and_next_message_drains() async throws {
        let mock = MockTransport()
        await mock.setAutoRespond(true)
        await mock.failNextTurnStartRequests(1)
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()
        let store = ConversationStore(rpc: rpc, threadId: "t1")

        await store.send(input: [.text("bad")], model: nil, effort: nil)
        try await waitUntil { store.failedOutbound != nil }
        await store.send(input: [.text("next")], model: nil, effort: nil)
        try await Task.sleep(nanoseconds: 50_000_000)
        let sendsBeforeDiscard = await mock.sent.filter { $0.contains("turn/start") }.count
        XCTAssertEqual(sendsBeforeDiscard, 1)

        let discarded = store.discardFailedSend()
        guard case .text(let discardedText)? = discarded?.input.first else {
            return XCTFail("expected failed text input")
        }
        XCTAssertEqual(discardedText, "bad")
        try await waitUntil { await mock.sent.filter { $0.contains("turn/start") }.count == 2 }
        XCTAssertNil(store.failedOutbound)
        XCTAssertFalse(store.state.items.contains { $0.id == discarded?.localId })
    }

    func test_failed_message_can_be_retried_without_duplicate_echo() async throws {
        let mock = MockTransport()
        await mock.setAutoRespond(true)
        await mock.failNextTurnStartRequests(1)
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()
        let store = ConversationStore(rpc: rpc, threadId: "t1")

        await store.send(input: [.text("retry")], model: nil, effort: nil)
        try await waitUntil { store.failedOutbound != nil }
        await store.retryLastSend()
        try await waitUntil { await mock.sent.filter { $0.contains("turn/start") }.count == 2 }

        let echoes = store.state.items.filter { if case .userMessage = $0 { return true }; return false }
        XCTAssertEqual(echoes.count, 1)
        XCTAssertNil(store.failedOutbound)
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

    private func replyToRecovery(_ mock: MockTransport,
                                 currentThreadId: String,
                                 resumeResult: String = "{}",
                                 noRollout: Bool = false) -> Task<Void, Never> {
        Task {
            var answered = Set<String>()
            for _ in 0..<500 {
                if Task.isCancelled { return }
                for frame in await mock.sent {
                    guard let object = try? JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any],
                          let id = object["id"] as? String,
                          let method = object["method"] as? String,
                          !answered.contains(id) else { continue }
                    if method == RPCMethod.threadLoadedList {
                        answered.insert(id)
                        await mock.feed(#"{"id":"\#(id)","result":{"data":[],"nextCursor":null}}"#)
                    } else if method == RPCMethod.threadResume,
                              (object["params"] as? [String: Any])?["threadId"] as? String == currentThreadId {
                        answered.insert(id)
                        if noRollout {
                            await mock.feed(#"{"id":"\#(id)","error":{"code":-32600,"message":"no rollout found for thread id \#(currentThreadId)"}}"#)
                        } else {
                            await mock.feed(#"{"id":"\#(id)","result":\#(resumeResult)}"#)
                        }
                    }
                }
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }
    }
}
