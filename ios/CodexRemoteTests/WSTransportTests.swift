import XCTest
@testable import CodexRemote

/// ws 物理通道测试替身：记录发出的文本，允许测试推入帧 / 模拟断开。
/// `openSucceeds` 控制 `waitUntilOpen()`：false 时模拟「新通道握手失败/不可达」。
actor FakeWebSocketChannel: WebSocketChannel {
    private(set) var sentTexts: [String] = []
    private let openSucceeds: Bool
    private var continuation: AsyncThrowingStream<String, Error>.Continuation?
    private nonisolated let stream: AsyncThrowingStream<String, Error>
    init(openSucceeds: Bool = true) {
        self.openSucceeds = openSucceeds
        var c: AsyncThrowingStream<String, Error>.Continuation!
        stream = AsyncThrowingStream(bufferingPolicy: .unbounded) { c = $0 }
        continuation = c
    }
    func send(text: String) async throws { sentTexts.append(text) }
    nonisolated func receive() -> AsyncThrowingStream<String, Error> { stream }
    func waitUntilOpen() async throws {
        // 模拟握手探测：openSucceeds=false 即「通道连不上」（探测失败 + 流随即结束）。
        if !openSucceeds {
            continuation?.finish(throwing: TransportError.channelClosed(reason: "open-failed"))
            continuation = nil
            throw TransportError.channelClosed(reason: "open-failed")
        }
    }
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

    // send() 直发裸 JSON-RPC 文本，不再包 {"type":"request",...} envelope（原样一帧发出）。
    func testSendEmitsRawJSONRPC() async throws {
        let fake = FakeWebSocketChannel()
        let t = WSTransport(connect: { _ in fake })
        await t.start()
        let raw = #"{"jsonrpc":"2.0","id":"ipad-1","method":"initialize","params":{}}"#
        try await t.send(raw)
        try await Task.sleep(nanoseconds: 50_000_000)
        let sent = await fake.sentTexts
        XCTAssertEqual(sent, [raw], "应原样发出裸 JSON-RPC，无 envelope 包裹")
    }

    // incoming() 直接 yield 收到的整帧文本（不解 envelope、不取 payload）。
    func testIncomingYieldsRawFrame() async throws {
        let fake = FakeWebSocketChannel()
        let t = WSTransport(connect: { _ in fake })
        await t.start()
        let frame = #"{"jsonrpc":"2.0","method":"thread/started","params":{"threadId":"x"}}"#
        let exp = expectation(description: "incoming")
        let box = ReceivedBox()
        Task {
            for try await line in t.incoming() {
                await box.set(line); exp.fulfill(); break
            }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        await fake.push(frame)
        await fulfillment(of: [exp], timeout: 2)
        let got = await box.value
        XCTAssertEqual(got, frame, "整帧裸 JSON-RPC 应原样透传给 incoming()")
    }

    /// URLSessionWebSocketChannel 用带 Authorization: Bearer 的 URLRequest 建连，token 不进 URL query。
    func testChannelUsesBearerHeaderNotQuery() {
        let url = URL(string: "ws://host:8900/")!
        let ch = URLSessionWebSocketChannel(url: url, bearerToken: "secret-abc")
        XCTAssertEqual(ch.requestForTesting.value(forHTTPHeaderField: "Authorization"), "Bearer secret-abc")
        XCTAssertFalse(ch.requestForTesting.url?.absoluteString.contains("token=") ?? true)
    }

    // 物理断开后重连：经 control() 先发 .reconnecting 再发 .ready，且不再发任何 resync 帧。
    func testReconnectEmitsReadyAndNoResync() async throws {
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

        let expReconnecting = expectation(description: "reconnecting")
        let expReady = expectation(description: "ready")
        Task {
            for await ev in t.control() {
                if ev == .reconnecting { expReconnecting.fulfill() }
                if ev == .ready { expReady.fulfill() }
            }
        }
        try await Task.sleep(nanoseconds: 40_000_000)
        await first.drop()                          // 触发重连到 second
        await fulfillment(of: [expReconnecting, expReady], timeout: 3)

        // 重连后的新 channel 不应被发任何 resync 帧
        try await Task.sleep(nanoseconds: 60_000_000)
        let sent = await second.sentTexts
        XCTAssertTrue(sent.allSatisfy { !$0.contains("resync") },
                      "去 seq 后重连不应补发 resync；实际: \(sent)")
        // incoming 逻辑流未结束
        let didFinish = await finished.value
        XCTAssertFalse(didFinish, "incoming() 流不应因 ws 抖动而结束")
    }

    // C1: 重连时若新通道仍连不上（握手失败/不可达），不得发假 .ready。
    // 必须保持 .reconnecting 重试，直到某条新通道真正连上才发恰好一次 .ready，
    // 且事件顺序为 .reconnecting … .ready（不得出现 .ready 早于真正连上）。
    func testReconnectDoesNotEmitReadyUntilChannelConnects() async throws {
        let first = FakeWebSocketChannel()                       // 首连成功
        let deadSecond = FakeWebSocketChannel(openSucceeds: false) // 重连第一跳：连不上
        let liveThird = FakeWebSocketChannel()                   // 重连第二跳：连上
        let channels = ChannelQueue([first, deadSecond, liveThird])
        let t = WSTransport(reconnectDelay: 0.01, connect: { _ in channels.next() })
        await t.start()

        let events = ControlEventLog()
        Task { for await ev in t.control() { await events.append(ev) } }

        try await Task.sleep(nanoseconds: 40_000_000)
        await first.drop()                                       // 触发重连

        // 等到最终 .ready（应来自 liveThird 真正连上后）。
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if await events.contains(.ready) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let log = await events.all
        XCTAssertTrue(log.contains(.ready), "最终应在真正连上后发 .ready，实际事件: \(log)")
        // 第一个事件必须是 .reconnecting，且 .ready 之前不得有第二个 .ready（无假 ready）。
        let readyCount = log.filter { $0 == .ready }.count
        XCTAssertEqual(readyCount, 1, "只应发恰好一次 .ready（连不上的中间跳不得发 ready）；实际: \(log)")
        XCTAssertEqual(log.first, .reconnecting, "重连应先发 .reconnecting；实际: \(log)")
        // .ready 必须晚于 .reconnecting（顺序正确，无「先假 ready 再 reconnecting」）。
        if let readyIdx = log.firstIndex(of: .ready),
           let reconnIdx = log.firstIndex(of: .reconnecting) {
            XCTAssertLessThan(reconnIdx, readyIdx, ".reconnecting 必须早于 .ready；实际: \(log)")
        }
    }
}

/// 收帧探针。
actor ReceivedBox {
    private(set) var value: String?
    func set(_ s: String) { value = s }
}

/// 控制事件按序记录探针。
actor ControlEventLog {
    private(set) var all: [TransportControlEvent] = []
    func append(_ ev: TransportControlEvent) { all.append(ev) }
    func contains(_ ev: TransportControlEvent) -> Bool { all.contains(ev) }
}
