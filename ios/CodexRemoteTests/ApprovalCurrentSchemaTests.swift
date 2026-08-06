import XCTest
@testable import CodexRemote

final class ApprovalCurrentSchemaTests: XCTestCase {
    @MainActor
    func testCommandRequestRetainsCurrentDecisionContext() throws {
        let request = try makeRequest(id: "cmd", method: ServerRequestMethod.cmdApprovalV2, params: #"{"threadId":"t","turnId":"turn","itemId":"item","startedAtMs":12,"command":"curl example.com","cwd":"/work","reason":"Needs network","networkApprovalContext":{"host":"example.com","protocol":"https"},"proposedExecpolicyAmendment":["curl"],"proposedNetworkPolicyAmendments":[{"host":"example.com","action":"allow"}]}"#)
        let payload = try ApprovalRequestDecoder.decode(request)
        guard case .command(let params) = payload else { return XCTFail("expected command") }
        XCTAssertEqual(params.itemId, "item")
        XCTAssertEqual(params.startedAtMs, 12)
        XCTAssertEqual(params.reason, "Needs network")
        XCTAssertEqual(params.networkApprovalContext?.host, "example.com")
        XCTAssertEqual(params.proposedNetworkPolicyAmendments?.first?.action, .allow)
    }

    @MainActor
    func testPermissionsRetainEntriesAccessAndGlobDepth() throws {
        let request = try makeRequest(id: "perms", method: ServerRequestMethod.permsApprovalV2, params: #"{"threadId":"t","turnId":"turn","itemId":"item","startedAtMs":13,"cwd":"/work","permissions":{"fileSystem":{"entries":[{"access":"read","path":{"type":"path","path":"/src"}},{"access":"deny","path":{"type":"glob_pattern","pattern":"**/.env"}}],"globScanMaxDepth":5}}}"#)
        let payload = try ApprovalRequestDecoder.decode(request)
        guard case .permissions(let params) = payload else { return XCTFail("expected permissions") }
        let fileSystem = try XCTUnwrap(params.permissions.fileSystem)
        XCTAssertEqual(fileSystem.globScanMaxDepth, 5)
        XCTAssertEqual(fileSystem.entries?.map(\.access), [.read, .deny])
        XCTAssertEqual(fileSystem.entries?.map(\.path.displayValue), ["/src", "**/.env"])
    }

    @MainActor
    func testMissingRequiredFieldGetsInvalidParamsAndNoCard() async throws {
        let mock = MockTransport()
        let rpc = JSONRPCClient(transport: mock)
        let store = ApprovalStore()
        let coordinator = ApprovalCoordinator(store: store, projects: ProjectsStore())
        await coordinator.bind(rpc: rpc)
        await rpc.start()

        await mock.feed(#"{"id":"bad","method":"item/commandExecution/requestApproval","params":{"threadId":"t","command":"ls"}}"#)
        try await waitUntil { !(await mock.sent.isEmpty) }
        XCTAssertTrue(store.cards.isEmpty)
        let lastFrame = await mock.sent.last
        let frame = try XCTUnwrap(lastFrame)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any])
        XCTAssertEqual((json["error"] as? [String: Any])?["code"] as? Int, -32602)
    }

    private func makeRequest(id: String, method: String, params: String) throws -> JSONRPCRequest {
        let paramsObject = try JSONSerialization.jsonObject(with: Data(params.utf8))
        let data = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": paramsObject])
        guard case .request(let request) = try JSONDecoder().decode(JSONRPCMessage.self, from: data) else {
            throw TestError.notRequest
        }
        return request
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 2, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("timed out waiting for condition")
    }

    private enum TestError: Error { case notRequest }
}
