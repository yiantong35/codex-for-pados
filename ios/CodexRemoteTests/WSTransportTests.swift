import XCTest
@testable import CodexRemote

/// ws 物理通道测试替身：记录发出的文本，允许测试推入帧 / 模拟断开。
actor FakeWebSocketChannel: WebSocketChannel {
    private(set) var sentTexts: [String] = []
    private var continuation: AsyncThrowingStream<String, Error>.Continuation?
    private nonisolated let stream: AsyncThrowingStream<String, Error>
    init() {
        var c: AsyncThrowingStream<String, Error>.Continuation!
        stream = AsyncThrowingStream(bufferingPolicy: .unbounded) { c = $0 }
        continuation = c
    }
    func send(text: String) async throws { sentTexts.append(text) }
    nonisolated func receive() -> AsyncThrowingStream<String, Error> { stream }
    func close() async { continuation?.finish(); continuation = nil }
    // 测试驱动
    func push(_ frame: String) { continuation?.yield(frame) }
    func drop() { continuation?.finish(throwing: TransportError.channelClosed(reason: "test-drop")) }
}

final class ChannelQueue: @unchecked Sendable {
    private var items: [FakeWebSocketChannel]
    private let lock = NSLock()
    init(_ items: [FakeWebSocketChannel]) { self.items = items }
    func next() -> FakeWebSocketChannel {
        lock.lock(); defer { lock.unlock() }
        return items.isEmpty ? FakeWebSocketChannel() : items.removeFirst()
    }
}
actor StreamFinishedBox {
    private(set) var value = false
    func markFinished() { value = true }
}

final class WSTransportTests: XCTestCase {
    // 未连接（channel 为 nil，如重连窗口内）send 应抛 .notConnected，而非静默丢弃导致请求挂起。
    func testSendThrowsWhenNotConnected() async {
        let t = WSTransport(connect: { _ in FakeWebSocketChannel() })
        // 未调用 start()，channel 仍为 nil
        do {
            try await t.send(#"{"id":"ipad-1","method":"thread/list"}"#)
            XCTFail("未连接时 send 应抛错")
        } catch {
            XCTAssertEqual(error as? TransportError, .notConnected)
        }
    }

    // send 出去的文本应是 request envelope
    func testSendWrapsAsRequestEnvelope() async throws {
        let fake = FakeWebSocketChannel()
        let t = WSTransport(connect: { _ in fake })
        await t.start()
        try await t.send(#"{"id":"ipad-1","method":"thread/list"}"#)
        try await Task.sleep(nanoseconds: 50_000_000)
        let sent = await fake.sentTexts
        XCTAssertEqual(sent.count, 1)
        let obj = try JSONSerialization.jsonObject(with: Data(sent[0].utf8)) as! [String: Any]
        XCTAssertEqual(obj["type"] as? String, "request")
    }

    // 入向 event → incoming() 收到解包后的一行 payload JSON
    func testIncomingUnwrapsEventPayload() async throws {
        let fake = FakeWebSocketChannel()
        let t = WSTransport(connect: { _ in fake })
        await t.start()
        let exp = expectation(description: "incoming")
        Task {
            for try await line in t.incoming() {
                let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
                if obj["id"] as? String == "ipad-1" { exp.fulfill(); break }
            }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        await fake.push(#"{"type":"event","seq":1,"payload":{"jsonrpc":"2.0","id":"ipad-1","result":{}}}"#)
        await fulfillment(of: [exp], timeout: 2)
    }

    // 连续 event → lastSeq 跟踪到最新
    func testLastSeqTracksLatestEvent() async throws {
        let fake = FakeWebSocketChannel()
        let t = WSTransport(connect: { _ in fake })
        await t.start()
        await fake.push(#"{"type":"event","seq":3,"payload":{"a":1}}"#)
        await fake.push(#"{"type":"event","seq":9,"payload":{"a":2}}"#)
        try await Task.sleep(nanoseconds: 80_000_000)
        let last = await t.lastSeqForTesting
        XCTAssertEqual(last, 9)
    }

    // 断开后自动重连：新通道收到 resync(after=lastSeq)，且 incoming() 流不结束。
    func testReconnectSendsResyncWithLastSeq() async throws {
        let first = FakeWebSocketChannel()
        let second = FakeWebSocketChannel()
        let channels = ChannelQueue([first, second])
        let t = WSTransport(reconnectDelay: 0.01, connect: { _ in channels.next() })
        await t.start()

        // 流消费者：跨重连应保持不结束（结束则 finished=true）。
        let finished = StreamFinishedBox()
        Task {
            for try await _ in t.incoming() {}
            await finished.markFinished()
        }
        // 先收一条 event 把 lastSeq 推到 5
        await first.push(#"{"type":"event","seq":5,"payload":{"a":1}}"#)
        try await Task.sleep(nanoseconds: 60_000_000)
        // 物理断开 → 触发重连到 second
        await first.drop()
        try await Task.sleep(nanoseconds: 150_000_000)
        // second 应收到 resync(after=5)
        let sent = await second.sentTexts
        XCTAssertTrue(sent.contains { $0.contains(#""type":"resync""#) && $0.contains(#""after":5"#) },
                      "重连后应发 resync(after=lastSeq=5)；实际: \(sent)")
        // incoming 逻辑流未结束
        let didFinish = await finished.value
        XCTAssertFalse(didFinish, "incoming() 流不应因 ws 抖动而结束")
    }

    // 重连期间控制通道发 reconnecting 然后 ready
    func testReconnectEmitsControlEvents() async throws {
        let first = FakeWebSocketChannel()
        let second = FakeWebSocketChannel()
        let channels = ChannelQueue([first, second])
        let t = WSTransport(reconnectDelay: 0.01, connect: { _ in channels.next() })
        await t.start()
        let expReconnecting = expectation(description: "reconnecting")
        let expReady = expectation(description: "ready")
        Task {
            for await ev in t.control() {
                if ev == .reconnecting { expReconnecting.fulfill() }
                if ev == .ready { expReady.fulfill() }
            }
        }
        try await Task.sleep(nanoseconds: 40_000_000)
        await first.drop()
        await fulfillment(of: [expReconnecting, expReady], timeout: 3)
    }

    func testSnapshotNeededEmitsControlEvent() async throws {
        let fake = FakeWebSocketChannel()
        let t = WSTransport(connect: { _ in fake })
        await t.start()
        let exp = expectation(description: "snapshot")
        Task {
            for await ev in t.control() where ev == .snapshotNeeded { exp.fulfill(); break }
        }
        try await Task.sleep(nanoseconds: 40_000_000)
        await fake.push(#"{"type":"snapshot-needed"}"#)
        await fulfillment(of: [exp], timeout: 2)
    }
}
