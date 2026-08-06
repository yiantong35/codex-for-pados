import XCTest
@testable import CodexRemote

final class UserInputStoreTests: XCTestCase {
    @MainActor
    func testGeneratedProtocolFixtureDecodes() throws {
        let bundle = Bundle(for: UserInputStoreTests.self)
        let url = try XCTUnwrap(bundle.url(forResource: "requestUserInput", withExtension: "json"))
        let data = try Data(contentsOf: url)
        guard case .request(let request) = try JSONDecoder().decode(JSONRPCMessage.self, from: data) else {
            return XCTFail("fixture did not decode as a request")
        }
        let card = try UserInputCard(request: request)
        XCTAssertEqual(card.id, .string("fixture-input"))
        XCTAssertEqual(card.questions.map(\.id), ["target", "token"])
    }

    @MainActor
    func testDecodesAllQuestionFieldsAndBuildsExactResponseShape() throws {
        let request = try makeRequest(
            id: "input-1",
            params: #"{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","questions":[{"id":"target","header":"Target","question":"Which target?","isOther":true,"isSecret":false,"options":[{"label":"Core","description":"Inspect core"},{"label":"TUI","description":"Inspect TUI"}]},{"id":"token","header":"Token","question":"Enter token","isOther":false,"isSecret":true,"options":null}],"autoResolutionMs":60000}"#
        )
        let card = try UserInputCard(request: request)

        XCTAssertEqual(card.threadId, "thread-1")
        XCTAssertEqual(card.questions.count, 2)
        XCTAssertEqual(card.questions[0].options?.map(\.label), ["Core", "TUI"])
        XCTAssertTrue(card.questions[1].isSecret)
        XCTAssertEqual(card.autoResolutionMs, 60_000)

        let response = try card.response(drafts: [
            "target": UserInputDraft(selectedOption: "TUI", freeform: ""),
            "token": UserInputDraft(selectedOption: nil, freeform: "s3cr3t"),
        ])
        let json = try jsonObject(response)
        let answers = try XCTUnwrap(json["answers"] as? [String: Any])
        XCTAssertEqual((answers["target"] as? [String: Any])?["answers"] as? [String], ["TUI"])
        XCTAssertEqual((answers["token"] as? [String: Any])?["answers"] as? [String], ["user_note: s3cr3t"])
    }

    @MainActor
    func testOtherFreeformIsMutuallyExclusiveAndAllQuestionsAreRequired() throws {
        let request = try makeRequest(
            id: "input-2",
            params: #"{"threadId":"t","turnId":"turn","itemId":"item","questions":[{"id":"choice","header":"Choice","question":"Pick","isOther":true,"isSecret":false,"options":[{"label":"A","description":"First"}]},{"id":"details","header":"Details","question":"Explain","isOther":true,"isSecret":false,"options":null}],"autoResolutionMs":null}"#
        )
        let card = try UserInputCard(request: request)

        XCTAssertFalse(card.isSubmittable(drafts: ["choice": .init(selectedOption: "A", freeform: "")]))
        XCTAssertTrue(card.isSubmittable(drafts: [
            "choice": .init(selectedOption: nil, freeform: "Custom"),
            "details": .init(selectedOption: nil, freeform: "Because"),
        ]))
        let response = try card.response(drafts: [
            "choice": .init(selectedOption: nil, freeform: "Custom"),
            "details": .init(selectedOption: nil, freeform: "Because"),
        ])
        let json = try jsonObject(response)
        let answers = json["answers"] as? [String: [String: [String]]]
        XCTAssertEqual(answers?["choice"]?["answers"], ["user_note: Custom"])
        XCTAssertEqual(answers?["details"]?["answers"], ["user_note: Because"])
    }

    @MainActor
    func testCancelCompletesWithEmptyAnswersAndOnlyOnce() async throws {
        let store = UserInputStore()
        var responses: [ToolRequestUserInputResponse] = []
        store.resolver = { _, response in responses.append(response); return true }
        try store.handle(request: makeRequest(id: "cancel", params: singleQuestionParams))
        let card = try XCTUnwrap(store.cards.first)

        let firstCancel = await store.cancel(card: card)
        let duplicateCancel = await store.cancel(card: card)
        XCTAssertTrue(firstCancel)
        XCTAssertFalse(duplicateCancel)
        XCTAssertEqual(responses.count, 1)
        XCTAssertTrue(responses[0].answers.isEmpty)
        XCTAssertTrue(store.cards.isEmpty)
    }

    @MainActor
    func testAutoResolutionUsesEmptyAnswersAndNeverGuessesSecret() async throws {
        let store = UserInputStore(sleep: { _ in })
        var responses: [ToolRequestUserInputResponse] = []
        store.resolver = { _, response in responses.append(response); return true }
        let params = #"{"threadId":"t","turnId":"turn","itemId":"item","questions":[{"id":"secret","header":"Secret","question":"Token?","isOther":false,"isSecret":true,"options":null}],"autoResolutionMs":1}"#
        try store.handle(request: makeRequest(id: "auto", params: params))

        for _ in 0..<100 where responses.isEmpty { await Task.yield() }
        XCTAssertEqual(responses.count, 1)
        XCTAssertTrue(responses[0].answers.isEmpty)
        XCTAssertTrue(store.cards.isEmpty)
    }

    @MainActor
    func testInteractionCancelsAutoResolutionAndDisconnectPreservesFailClosedCard() async throws {
        let store = UserInputStore(sleep: { _ in try await Task.sleep(nanoseconds: 60_000_000_000) })
        var responseCount = 0
        store.resolver = { _, _ in responseCount += 1; return true }
        let params = singleQuestionParams.replacingOccurrences(of: #""autoResolutionMs":null"#, with: #""autoResolutionMs":1000"#)
        let request = try makeRequest(id: "recover", params: params)
        try store.handle(request: request)
        let card = try XCTUnwrap(store.cards.first)

        XCTAssertNotNil(store.autoResolutionDeadline(for: card.id))

        store.userInteracted(with: card.id)
        XCTAssertNil(store.autoResolutionDeadline(for: card.id))
        XCTAssertTrue(store.isAutoResolutionPaused(card.id))
        store.handleConnectionLost()
        XCTAssertEqual(responseCount, 0)
        XCTAssertTrue(store.cards[0].awaitingRecovery)

        try store.handle(request: request)
        XCTAssertEqual(store.cards.count, 1)
        XCTAssertFalse(store.cards[0].awaitingRecovery)
    }

    @MainActor
    func testFailedSubmissionIsVisibleAndCanRetry() async throws {
        let store = UserInputStore()
        var attempts = 0
        store.resolver = { _, _ in attempts += 1; return attempts == 2 }
        try store.handle(request: makeRequest(id: "retry", params: singleQuestionParams))
        let card = try XCTUnwrap(store.cards.first)
        let drafts = ["q": UserInputDraft(selectedOption: "A", freeform: "")]

        let first = await store.submit(card: card, drafts: drafts)
        XCTAssertFalse(first)
        XCTAssertEqual(store.submissionState(for: card.id), .failed)
        let second = await store.submit(card: card, drafts: drafts)
        XCTAssertTrue(second)
        XCTAssertTrue(store.cards.isEmpty)
    }

    private let singleQuestionParams = #"{"threadId":"t","turnId":"turn","itemId":"item","questions":[{"id":"q","header":"Question","question":"Choose","isOther":false,"isSecret":false,"options":[{"label":"A","description":"First"}]}],"autoResolutionMs":null}"#

    private func makeRequest(id: String, params: String) throws -> JSONRPCRequest {
        let paramsObject = try JSONSerialization.jsonObject(with: Data(params.utf8))
        let data = try JSONSerialization.data(withJSONObject: [
            "id": id,
            "method": ServerRequestMethod.userInput,
            "params": paramsObject,
        ])
        guard case .request(let request) = try JSONDecoder().decode(JSONRPCMessage.self, from: data) else {
            throw TestError.notRequest
        }
        return request
    }

    private func jsonObject(_ response: ToolRequestUserInputResponse) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? [String: Any])
    }

    private enum TestError: Error { case notRequest }
}
