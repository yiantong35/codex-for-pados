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

final class WSTransportTests: XCTestCase {
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
}
