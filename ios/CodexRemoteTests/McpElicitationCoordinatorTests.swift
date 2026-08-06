import XCTest
@testable import CodexRemote

final class McpElicitationCoordinatorTests: XCTestCase {
    @MainActor
    func testRoutesFormAndSendsExactResponse() async throws {
        let mock = MockTransport()
        let rpc = JSONRPCClient(transport: mock)
        let store = McpElicitationStore()
        let coordinator = McpElicitationCoordinator(store: store)
        await coordinator.bind(rpc: rpc)
        await rpc.start()

        await mock.feed(#"{"id":"mcp-1","method":"mcpServer/elicitation/request","params":{"threadId":"t","serverName":"forms","mode":"form","message":"Name","requestedSchema":{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}}}"#)
        try await waitUntil { !store.cards.isEmpty }
        let card = try XCTUnwrap(store.cards.first)
        let delivered = await store.accept(card: card, drafts: ["name": .text("Ada")])
        XCTAssertTrue(delivered)

        let lastFrame = await mock.sent.last
        let frame = try XCTUnwrap(lastFrame)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any])
        XCTAssertEqual(json["id"] as? String, "mcp-1")
        let result = try XCTUnwrap(json["result"] as? [String: Any])
        XCTAssertEqual(result["action"] as? String, "accept")
        XCTAssertEqual((result["content"] as? [String: Any])?["name"] as? String, "Ada")
    }

    @MainActor
    func testMalformedSchemaReceivesInvalidParamsError() async throws {
        let mock = MockTransport()
        let rpc = JSONRPCClient(transport: mock)
        let coordinator = McpElicitationCoordinator(store: McpElicitationStore())
        await coordinator.bind(rpc: rpc)
        await rpc.start()

        await mock.feed(#"{"id":"bad-mcp","method":"mcpServer/elicitation/request","params":{"threadId":"t","serverName":"x","mode":"form","message":"Nested","requestedSchema":{"type":"object","properties":{"nested":{"type":"object"}}}}}"#)
        try await waitUntil { !(await mock.sent.isEmpty) }
        let lastFrame = await mock.sent.last
        let frame = try XCTUnwrap(lastFrame)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any])
        let error = try XCTUnwrap(json["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32602)
    }

    @MainActor
    func testResolvedNotificationRemovesCardAndOwnership() async throws {
        let mock = MockTransport()
        let rpc = JSONRPCClient(transport: mock)
        let store = McpElicitationStore()
        let coordinator = McpElicitationCoordinator(store: store)
        await coordinator.bind(rpc: rpc)
        await rpc.start()

        await mock.feed(#"{"id":"mcp-2","method":"mcpServer/elicitation/request","params":{"threadId":"t","serverName":"x","mode":"url","message":"Authorize","url":"https://example.com","elicitationId":"e"}}"#)
        try await waitUntil { !store.cards.isEmpty }
        await mock.feed(#"{"method":"serverRequest/resolved","params":{"requestId":"mcp-2"}}"#)
        try await waitUntil { store.cards.isEmpty }
        let late = try await rpc.respond(to: .string("mcp-2"), result: AnyCodable(["action": "cancel"]))
        XCTAssertFalse(late)
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
}
