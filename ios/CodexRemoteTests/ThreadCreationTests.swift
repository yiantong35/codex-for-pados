import XCTest
@testable import CodexRemote

@MainActor
final class ThreadCreationTests: XCTestCase {
    func testStartSendsThreadStart() async throws {
        let mock = MockTransport()
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()
        let store = ConversationStore(rpc: rpc, threadId: "t1")

        await store.start(cwd: "/repo", model: "gpt-5")
        try await Task.sleep(nanoseconds: 200_000_000)

        let sent = await mock.sent
        XCTAssertTrue(sent.contains { $0.contains("thread/start") },
                      "应发 thread/start；实际：\(sent)")
        XCTAssertTrue(sent.contains { $0.contains("\"cwd\":\"/repo\"") },
                      "thread/start 应携带 cwd；实际：\(sent)")
    }

    func testForkSendsThreadForkWithSourceId() async throws {
        let mock = MockTransport()
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()
        let store = ConversationStore(rpc: rpc, threadId: "src-thread")

        Task { _ = await store.fork() }
        try await Task.sleep(nanoseconds: 200_000_000)

        let sent = await mock.sent
        XCTAssertTrue(sent.contains { $0.contains("thread/fork") },
                      "应发 thread/fork；实际：\(sent)")
        XCTAssertTrue(sent.contains { $0.contains("\"threadId\":\"src-thread\"") },
                      "thread/fork 应携带源 threadId；实际：\(sent)")
    }

    func testParamsShapeMatchesProtocol() {
        // 参数类型在编解码层面对齐 protocol v2（method 名常量）。
        XCTAssertEqual(RPCMethod.threadStart, "thread/start")
        XCTAssertEqual(RPCMethod.threadFork, "thread/fork")
    }
}
