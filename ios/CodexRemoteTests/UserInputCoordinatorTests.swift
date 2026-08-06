import XCTest
@testable import CodexRemote

final class UserInputCoordinatorTests: XCTestCase {
    @MainActor
    func testRoutesRequestAndSendsExactResponse() async throws {
        let mock = MockTransport()
        let rpc = JSONRPCClient(transport: mock)
        let store = UserInputStore()
        let coordinator = UserInputCoordinator(store: store)
        await coordinator.bind(rpc: rpc)
        await rpc.start()

        await mock.feed(#"{"id":"input-1","method":"item/tool/requestUserInput","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","questions":[{"id":"target","header":"Target","question":"Which?","isOther":false,"isSecret":false,"options":[{"label":"Core","description":"Core target"}]}],"autoResolutionMs":null}}"#)
        try await waitUntil { !store.cards.isEmpty }
        let card = try XCTUnwrap(store.cards.first)
        let delivered = await store.submit(
            card: card,
            drafts: ["target": .init(selectedOption: "Core", freeform: "")]
        )
        XCTAssertTrue(delivered)

        let lastFrame = await mock.sent.last
        let frame = try XCTUnwrap(lastFrame)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any])
        XCTAssertEqual(json["id"] as? String, "input-1")
        let result = try XCTUnwrap(json["result"] as? [String: Any])
        let answers = try XCTUnwrap(result["answers"] as? [String: Any])
        XCTAssertEqual((answers["target"] as? [String: Any])?["answers"] as? [String], ["Core"])
    }

    @MainActor
    func testMalformedParamsReceiveInvalidParamsError() async throws {
        let mock = MockTransport()
        let rpc = JSONRPCClient(transport: mock)
        let coordinator = UserInputCoordinator(store: UserInputStore())
        await coordinator.bind(rpc: rpc)
        await rpc.start()

        await mock.feed(#"{"id":"bad-input","method":"item/tool/requestUserInput","params":{"threadId":"thread-1"}}"#)
        try await waitUntil { !(await mock.sent.isEmpty) }
        let lastFrame = await mock.sent.last
        let frame = try XCTUnwrap(lastFrame)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any])
        let error = try XCTUnwrap(json["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32602)
    }

    @MainActor
    func testResolvedNotificationRemovesPendingCard() async throws {
        let mock = MockTransport()
        let rpc = JSONRPCClient(transport: mock)
        let store = UserInputStore()
        let coordinator = UserInputCoordinator(store: store)
        await coordinator.bind(rpc: rpc)
        await rpc.start()

        await mock.feed(#"{"id":"input-2","method":"item/tool/requestUserInput","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","questions":[{"id":"q","header":"Q","question":"Question","isOther":false,"isSecret":false,"options":null}],"autoResolutionMs":null}}"#)
        try await waitUntil { !store.cards.isEmpty }
        await mock.feed(#"{"method":"serverRequest/resolved","params":{"threadId":"thread-1","requestId":"input-2"}}"#)
        try await waitUntil { store.cards.isEmpty }

        let late = try await rpc.respond(to: .string("input-2"), result: AnyCodable(["answers": [:]]))
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
