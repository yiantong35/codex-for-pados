import XCTest
@testable import CodexRemote

@MainActor
final class ApprovalBoundaryTests: XCTestCase {
    private func cardStore() -> ApprovalStore {
        let store = ApprovalStore()
        let req = JSONRPCRequest(id: .string("r1"),
            method: ServerRequestMethod.cmdApprovalV2,
            params: AnyCodable(["threadId": "t1", "command": "ls"]))
        store.handle(request: req)
        return store
    }

    func testResolvedByOtherRemovesCard() {
        let store = cardStore()
        XCTAssertEqual(store.cards.count, 1)
        store.handleServerRequestResolved(requestId: .string("r1"), threadId: "t1")
        XCTAssertTrue(store.cards.isEmpty)        // 他端处理后移除
    }

    func testResolvedByOtherDoesNotAutoApprove() {
        let store = cardStore()
        var autoApproved = false
        store.resolver = { _, _ in autoApproved = true }
        store.handleServerRequestResolved(requestId: .string("r1"), threadId: "t1")
        XCTAssertFalse(autoApproved)              // 他端解决也绝不回传 approve
    }

    func testDisconnectMarksPendingNotAutoApproved() async {
        let store = cardStore()
        var autoApproved = false
        store.resolver = { _, _ in autoApproved = true }    // 若被调用即视为自动回传
        store.handleConnectionLost()
        XCTAssertFalse(autoApproved)                 // 绝不自动批准
        XCTAssertTrue(store.cards.first?.awaitingRecovery ?? false)  // 标记待恢复
    }

    func testServerRequestStreamEndDoesNotAutoApprove() async throws {
        // 断线：MockTransport.close() 致 serverRequests 流结束。绝不应有未经用户的 approve。
        let mock = MockTransport()
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()
        let coord = ApprovalCoordinator(store: ApprovalStore(), projects: ProjectsStore())
        coord.bind(rpc: rpc)
        let store = coord.store

        let frame = #"{"jsonrpc":"2.0","id":"r1","method":"item/commandExecution/requestApproval","params":{"threadId":"t1","command":"ls"}}"#
        await mock.feed(frame)
        // 等待卡片入队
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, store.cards.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(store.cards.count, 1)

        await mock.close()                       // 断线
        try await Task.sleep(nanoseconds: 100_000_000)
        let sent = await mock.sent
        XCTAssertTrue(sent.isEmpty)              // 绝不自动批准（无任何 response 发出）
    }
}
