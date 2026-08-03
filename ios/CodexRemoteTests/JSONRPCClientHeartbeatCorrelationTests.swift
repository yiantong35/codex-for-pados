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
