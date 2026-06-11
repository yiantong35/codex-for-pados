import XCTest
@testable import CodexRemote

@MainActor
final class ApprovalStoreTests: XCTestCase {
    func testV2CommandRequestEnqueuesCard() async throws {
        let store = ApprovalStore()
        let req = JSONRPCRequest(id: .string("r1"),
            method: ServerRequestMethod.cmdApprovalV2,
            params: AnyCodable(["threadId": "t1", "turnId": "T1", "itemId": "I1", "command": "rm -rf x"]))
        store.handle(request: req)
        XCTAssertEqual(store.cards.count, 1)
        XCTAssertEqual(store.cards.first?.threadId, "t1")
        XCTAssertEqual(store.cards.first?.title, "rm -rf x")
        XCTAssertFalse(store.cards.first?.isFileChange ?? true)
    }

    func testV2ApproveEncodesAccept() throws {
        let store = ApprovalStore()
        let resp = store.responseBody(for: ServerRequestMethod.cmdApprovalV2, decision: .approve)
        let s = String(data: try JSONEncoder().encode(resp), encoding: .utf8)!
        XCTAssertTrue(s.contains("accept"))
    }

    func testV2ApproveWithPrefixEncodesAmendment() throws {
        let store = ApprovalStore()
        let resp = store.responseBody(for: ServerRequestMethod.cmdApprovalV2,
                                      decision: .approveForSessionPrefix(["git", "status"]))
        let s = String(data: try JSONEncoder().encode(resp), encoding: .utf8)!
        XCTAssertTrue(s.contains("acceptWithExecpolicyAmendment"))
        XCTAssertTrue(s.contains("execpolicy_amendment"))
    }

    func testV2DeclineEncodes() throws {
        let store = ApprovalStore()
        let resp = store.responseBody(for: ServerRequestMethod.cmdApprovalV2, decision: .deny)
        XCTAssertTrue(String(data: try JSONEncoder().encode(resp), encoding: .utf8)!.contains("decline"))
    }

    func testLegacyExecApprovalUsesReviewDecision() throws {
        let store = ApprovalStore()
        let resp = store.responseBody(for: ServerRequestMethod.execApprovalLegacy, decision: .approve)
        XCTAssertTrue(String(data: try JSONEncoder().encode(resp), encoding: .utf8)!.contains("approved"))
    }

    func testLegacyDenyUsesReviewDecisionDenied() throws {
        let store = ApprovalStore()
        let resp = store.responseBody(for: ServerRequestMethod.execApprovalLegacy, decision: .deny)
        XCTAssertTrue(String(data: try JSONEncoder().encode(resp), encoding: .utf8)!.contains("denied"))
    }

    func testFileChangeV2EnqueuesFileCard() throws {
        let store = ApprovalStore()
        let req = JSONRPCRequest(id: .string("f1"),
            method: ServerRequestMethod.fileApprovalV2,
            params: AnyCodable(["threadId": "t1", "file": "main.swift", "diff": "+ line"]))
        store.handle(request: req)
        XCTAssertEqual(store.cards.first?.isFileChange, true)
    }

    // 端到端：经 JSONRPCClient.serverRequests() feed → 真实 coordinator 接线 → resolve → mock.sent 含正确 response。
    func testResolveSendsResponseWithMatchingRequestId() async throws {
        let mock = MockTransport()
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()
        let coord = ApprovalCoordinator(store: ApprovalStore(), projects: ProjectsStore())
        coord.bind(rpc: rpc)
        let store = coord.store

        let frame = #"{"jsonrpc":"2.0","id":"r9","method":"item/commandExecution/requestApproval","params":{"threadId":"t1","command":"ls"}}"#
        await mock.feed(frame)
        // 等待 server-request 流送达
        try await waitUntil { store.cards.count == 1 }
        let card = store.cards.first!
        await store.resolve(card: card, choice: .approve)
        try await waitUntil { await mock.sent.contains { $0.contains("\"id\":\"r9\"") } }
        let sent = await mock.sent
        let respFrame = sent.first { $0.contains("\"id\":\"r9\"") }!
        XCTAssertTrue(respFrame.contains("accept"))
        XCTAssertTrue(store.cards.isEmpty)
    }

    // 辅助：轮询直到条件满足或超时。
    private func waitUntil(timeout: TimeInterval = 2,
                           _ cond: @escaping () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await cond() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("waitUntil 超时")
    }
}
