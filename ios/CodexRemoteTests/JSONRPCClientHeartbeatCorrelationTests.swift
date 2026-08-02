import XCTest
@testable import CodexRemote

/// 心跳前置刻画（design §1.2）：确认 `JSONRPCClient.send(method:params:)` 已按 JSON-RPC id
/// 关联请求-响应，可直接复用作端到端心跳（发 `getAuthStatus`、按其 id 收回响）。
final class JSONRPCClientHeartbeatCorrelationTests: XCTestCase {
    /// 心跳依赖「发一个 getAuthStatus 请求、按其 JSON-RPC id 收回响」。
    /// 本测试刻画该关联可用：send 挂起直到喂入同 id 的 response 才返回。
    func test_send_awaitsResponseById() async throws {
        let mock = MockTransport()
        let client = JSONRPCClient(transport: mock)
        await client.start()
        let empty = try JSONDecoder().decode(AnyCodable.self, from: Data("{}".utf8))

        let probe = Task { try await client.send(method: RPCMethod.getAuthStatus, params: empty) }
        // 取出 send 出去的请求 id，构造同 id 的成功响应喂回。
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

    /// 轮询条件直到为真或超时（复制自 ConnectionStoreTests，避免跨文件作用域依赖）。
    private func waitUntil(timeout: TimeInterval = 3,
                           _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("waitUntil 超时")
    }
}
