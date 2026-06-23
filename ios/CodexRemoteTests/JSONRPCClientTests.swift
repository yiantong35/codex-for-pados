import XCTest
@testable import CodexRemote

final class JSONRPCClientTests: XCTestCase {
    // ① call 发出请求后，feed 对应 id 的 response → call 返回正确 result
    func testRequestResolvesByMatchingId() async throws {
        let mock = MockTransport()
        let client = JSONRPCClient(transport: mock)
        await client.start()
        async let result: AnyCodable = client.send(method: "thread/list", params: AnyCodable(["limit": 1]))
        // 取出客户端发出的请求，回填一条匹配 id 的响应
        var sent: String?
        for _ in 0..<100 {
            try await Task.sleep(nanoseconds: 10_000_000)
            if let first = await mock.sent.first { sent = first; break }
        }
        XCTAssertNotNil(sent)
        XCTAssertTrue(sent!.contains("thread/list"))
        let obj = try JSONSerialization.jsonObject(with: Data(sent!.utf8)) as! [String: Any]
        let myId = obj["id"] as! String
        await mock.feed(#"{"jsonrpc":"2.0","id":"\#(myId)","result":{"data":[]}}"#)
        let r = try await result
        // result.value 应为 {"data": []}
        let dict = r.value as? [String: Any]
        XCTAssertNotNil(dict?["data"])
    }

    // ② feed 一条 notification → 通知流收到
    func testNotificationsFlowToStream() async throws {
        let mock = MockTransport()
        let client = JSONRPCClient(transport: mock)
        await client.start()
        let exp = expectation(description: "notif")
        Task {
            for await n in await client.notifications() {
                if n.method == "item/agentMessage/delta" { exp.fulfill(); break }
            }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        await mock.feed(#"{"jsonrpc":"2.0","method":"item/agentMessage/delta","params":{"delta":"hi"}}"#)
        await fulfillment(of: [exp], timeout: 1)
    }

    // ②b 多播：两个并发消费者都应收到同一条通知。
    // 旧实现 notifications() 返回同一个单 continuation 流（单消费者语义），
    // 事件被两个 for-await 瓜分，至多一个消费者拿到 → 本用例 RED。
    func testNotificationsMulticastToMultipleConsumers() async throws {
        let mock = MockTransport()
        let client = JSONRPCClient(transport: mock)
        await client.start()
        let expA = expectation(description: "consumerA")
        let expB = expectation(description: "consumerB")
        Task {
            for await n in await client.notifications() {
                if n.method == "item/agentMessage/delta" { expA.fulfill(); break }
            }
        }
        Task {
            for await n in await client.notifications() {
                if n.method == "item/agentMessage/delta" { expB.fulfill(); break }
            }
        }
        try await Task.sleep(nanoseconds: 80_000_000)   // 让两个订阅者就位
        await mock.feed(#"{"jsonrpc":"2.0","method":"item/agentMessage/delta","params":{"delta":"hi"}}"#)
        await fulfillment(of: [expA, expB], timeout: 2)
    }

    // ②c 多播订阅者在底层 transport 关闭后流应结束（ConnectionStore 的断线探测依赖此）。
    func testNotificationStreamFinishesOnTransportClose() async throws {
        let mock = MockTransport()
        let client = JSONRPCClient(transport: mock)
        await client.start()
        let exp = expectation(description: "stream-finished")
        Task {
            for await _ in await client.notifications() { }
            exp.fulfill()   // 流自然结束才会到这里
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        await mock.close()
        await fulfillment(of: [exp], timeout: 2)
    }

    // ③ feed 一条 server request → server-request 处理器收到且 method/id 正确，并回 response
    func testServerRequestDispatchedToHandler() async throws {
        let mock = MockTransport()
        let client = JSONRPCClient(transport: mock)
        await client.setServerRequestHandler { req in
            XCTAssertEqual(req.method, "item/commandExecution/requestApproval")
            return AnyCodable(["decision": "decline"])
        }
        await client.start()
        await mock.feed(#"{"jsonrpc":"2.0","id":"r1","method":"item/commandExecution/requestApproval","params":{}}"#)
        try await Task.sleep(nanoseconds: 150_000_000)
        let replied = await mock.sent.last
        XCTAssertNotNil(replied)
        XCTAssertTrue(replied!.contains(#""id":"r1""#))
        XCTAssertTrue(replied!.contains("decline"))
    }

    // ④ feed 对应 id 的 error → call 抛错
    func testErrorResponseThrows() async throws {
        let mock = MockTransport()
        let client = JSONRPCClient(transport: mock)
        await client.start()
        async let result: AnyCodable = client.send(method: "thread/list", params: nil)
        var sent: String?
        for _ in 0..<100 {
            try await Task.sleep(nanoseconds: 10_000_000)
            if let first = await mock.sent.first { sent = first; break }
        }
        XCTAssertNotNil(sent)
        let obj = try JSONSerialization.jsonObject(with: Data(sent!.utf8)) as! [String: Any]
        let myId = obj["id"] as! String
        await mock.feed(#"{"jsonrpc":"2.0","id":"\#(myId)","error":{"code":-32000,"message":"boom"}}"#)
        do {
            _ = try await result
            XCTFail("应抛错")
        } catch {
            // 期望 TransportError.proxyFailed("boom")
            XCTAssertEqual(error as? TransportError, .proxyFailed("boom"))
        }
    }

    // ⑤ 喂入他人 id 的 response/error 不影响本端 pending 请求。
    func testForeignIdResponseIgnored() async throws {
        let mock = MockTransport()
        let client = JSONRPCClient(transport: mock)
        await client.start()
        async let result: AnyCodable = client.send(method: "thread/list", params: nil)
        // 等本端请求发出，取出其唯一 id
        var myId: String?
        for _ in 0..<200 {
            try await Task.sleep(nanoseconds: 5_000_000)
            if let first = await mock.sent.first,
               let obj = try? JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any],
               let id = obj["id"] as? String { myId = id; break }
        }
        XCTAssertNotNil(myId)
        // 先喂一条「别人 id」的 error（不应让本请求抛错或被误消费）
        await mock.feed(#"{"jsonrpc":"2.0","id":"mac-999","error":{"code":-32000,"message":"not mine"}}"#)
        try await Task.sleep(nanoseconds: 50_000_000)
        // 再喂本端 id 的正确 response → 本请求应正常返回
        await mock.feed(#"{"jsonrpc":"2.0","id":"\#(myId!)","result":{"ok":true}}"#)
        let r = try await result
        XCTAssertNotNil((r.value as? [String: Any])?["ok"])
    }

    // ⑥ send 出向请求 id 是 ipad- 前缀的全局唯一 string id
    func testSendUsesUniqueStringId() async throws {
        let mock = MockTransport()
        let client = JSONRPCClient(transport: mock)
        await client.start()
        async let result: AnyCodable = client.send(method: "thread/list", params: nil)
        var sent: String?
        for _ in 0..<200 {
            try await Task.sleep(nanoseconds: 5_000_000)
            if let f = await mock.sent.first { sent = f; break }
        }
        let obj = try JSONSerialization.jsonObject(with: Data(sent!.utf8)) as! [String: Any]
        let myId = obj["id"] as? String
        XCTAssertTrue(myId?.hasPrefix("ipad-") ?? false)
        // 回填匹配 id 的 response 让 send 正常返回，避免 async let 在 scope 结束时永久挂起
        await mock.feed(#"{"jsonrpc":"2.0","id":"\#(myId!)","result":{}}"#)
        _ = try await result
    }
}
