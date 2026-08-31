import XCTest
@testable import CodexRemote

/// 心跳前置刻画（design §1.2）：确认 JSONRPCClient.send(method:params:) 已按 JSON-RPC id
/// 关联请求-响应，可直接复用作端到端心跳（发 getAuthStatus、按其 id 收回响）。
final class JSONRPCClientHeartbeatCorrelationTests: XCTestCase {
    func test_send_awaitsResponseById() async throws {
        let mock = MockTransport()
        let client = JSONRPCClient(transport: mock)
        await client.start()
        let empty = try JSONDecoder().decode(AnyCodable.self, from: Data("{}".utf8))

        let probe = Task { try await client.send(method: RPCMethod.getAuthStatus, params: empty) }
        try await waitUntil { await !mock.sent.isEmpty }
        let sentText = await mock.sent[0]
        let id = try Self.extractId(from: sentText)
        await mock.feed(#"{"jsonrpc":"2.0","id":\#(id),"result":{}}"#)

        _ = try await probe.value   // 不抛 = 按 id 成功关联回响
    }

    // MARK: - 流量即活（heartbeat-liveness-and-resume-guards）

    /// 流量即活挂钩点 = 唯一入站分发入口：成功解码的消息（notification / 孤儿 response 均可）触发回调。
    func test_inboundActivity_firesForDecodedMessages() async throws {
        let mock = MockTransport()
        let client = JSONRPCClient(transport: mock)
        let hits = Counter()   // Counter actor 定义于 HeartbeatMonitorTests.swift，同 target 复用
        await client.setInboundActivityHandler { Task { await hits.increment() } }
        await client.start()
        await mock.feed(#"{"jsonrpc":"2.0","method":"turn/started","params":{"threadId":"t1"}}"#)
        try await waitUntil { await hits.value == 1 }
        await mock.feed(#"{"jsonrpc":"2.0","id":"orphan","result":{}}"#)  // 无 pending 的孤儿响应也是流量
        try await waitUntil { await hits.value == 2 }
    }

    /// 防降级（伪造流量不能维持假活）：解码失败的入站行不触发回调。
    /// 论证链：未通过 E2E 验证的帧根本到不了本 client——RelayTransport 仅 emit
    /// SecureSession.open（AEAD+计数单调）验证成功的明文（本 change 对其零改动，既有
    /// AEAD fail-closed 测试锁定）；本测试锁最后一层「client 入站入口对垃圾行不计活」。
    func test_inboundActivity_doesNotFireForUndecodableLines() async throws {
        let mock = MockTransport()
        let client = JSONRPCClient(transport: mock)
        let hits = Counter()
        await client.setInboundActivityHandler { Task { await hits.increment() } }
        await client.start()
        await mock.feed("💥 not-json-at-all")
        try? await Task.sleep(nanoseconds: 100_000_000)
        let afterGarbage = await hits.value
        XCTAssertEqual(afterGarbage, 0, "解码失败的行不得计为存活流量")
        await mock.feed(#"{"jsonrpc":"2.0","method":"turn/started","params":{}}"#)
        try await waitUntil { await hits.value == 1 }   // 回调路径本身是活的，垃圾行确实没计数
    }

    private static func extractId(from json: String) throws -> String {
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        if let n = obj["id"] as? NSNumber { return n.stringValue }
        return "\"\(obj["id"] as! String)\""
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("waitUntil 超时")
    }
}
