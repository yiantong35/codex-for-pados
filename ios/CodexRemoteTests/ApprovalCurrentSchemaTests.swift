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
    func testPermissionsRejectExcessiveEntriesAndPathLength() throws {
        let entries = (0...PermissionRequestLimits.maximumEntries).map {
            "{\"access\":\"read\",\"path\":{\"type\":\"path\",\"path\":\"/p\($0)\"}}"
        }.joined(separator: ",")
        let params = "{\"threadId\":\"t\",\"turnId\":\"turn\",\"itemId\":\"item\",\"startedAtMs\":1,\"cwd\":\"/work\",\"permissions\":{\"fileSystem\":{\"entries\":[\(entries)]}}}"
        XCTAssertThrowsError(try ApprovalRequestDecoder.decode(makeRequest(id: "too-many", method: ServerRequestMethod.permsApprovalV2, params: params)))
        let longPath = String(repeating: "x", count: PermissionRequestLimits.maximumPathBytes + 1)
        let longParams = "{\"threadId\":\"t\",\"turnId\":\"turn\",\"itemId\":\"item\",\"startedAtMs\":1,\"cwd\":\"/work\",\"permissions\":{\"fileSystem\":{\"entries\":[{\"access\":\"read\",\"path\":{\"type\":\"path\",\"path\":\"/\(longPath)\"}}]}}}"
        XCTAssertThrowsError(try ApprovalRequestDecoder.decode(makeRequest(id: "too-long", method: ServerRequestMethod.permsApprovalV2, params: longParams)))
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

    @MainActor
    func testFileApprovalCorrelatesOnlyExactItemId() throws {
        let request = try makeRequest(id: "file", method: ServerRequestMethod.fileApprovalV2, params: #"{"threadId":"t","turnId":"turn","itemId":"target","startedAtMs":14,"reason":"Write","grantRoot":"/work"}"#)
        let store = ApprovalStore()
        try store.handleValidated(request: request)
        let card = try XCTUnwrap(store.cards.first)
        let items: [ConversationItem] = [
            .fileChange(id: "other", file: "main.swift", added: 1, removed: 0, diff: "+ wrong"),
            .fileChange(id: "target", file: "main.swift", added: 2, removed: 1, diff: "+ right"),
        ]
        let context = try XCTUnwrap(ApprovalPresentation.fileContext(for: card, in: items))
        XCTAssertEqual(context.file, "main.swift")
        XCTAssertEqual(context.diff, "+ right")
        XCTAssertNil(ApprovalPresentation.fileContext(for: card, in: Array(items.prefix(1))))
    }

    @MainActor
    func testPermissionApprovalPreservesEntriesAndDepth() async throws {
        let request = try makeRequest(id: "perms-response", method: ServerRequestMethod.permsApprovalV2, params: #"{"threadId":"t","turnId":"turn","itemId":"item","startedAtMs":15,"cwd":"/work","permissions":{"fileSystem":{"entries":[{"access":"write","path":{"type":"path","path":"/out"}}],"globScanMaxDepth":7}}}"#)
        let store = ApprovalStore()
        var result: AnyCodable?
        store.resolver = { _, response in result = response; return true }
        try store.handleValidated(request: request)
        let card = try XCTUnwrap(store.cards.first)
        let delivered = await store.resolve(card: card, choice: .approveForSessionPrefix([]))
        XCTAssertTrue(delivered)
        let encoded = try JSONEncoder().encode(try XCTUnwrap(result))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(json["scope"] as? String, "session")
        let fileSystem = try XCTUnwrap((json["permissions"] as? [String: Any])?["fileSystem"] as? [String: Any])
        XCTAssertEqual(fileSystem["globScanMaxDepth"] as? Int, 7)
        XCTAssertEqual(((fileSystem["entries"] as? [[String: Any]])?.first)?["access"] as? String, "write")
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
