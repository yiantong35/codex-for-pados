import XCTest
@testable import CodexRemote

final class McpElicitationTests: XCTestCase {
    @MainActor
    func testURLModeDecodesAndBuildsActionsWithoutContent() throws {
        let request = try makeRequest(id: "url-1", params: #"{"threadId":"t","turnId":null,"serverName":"github","mode":"url","message":"Authorize access","url":"https://example.com/auth","elicitationId":"e-1","_meta":{"trace":"x"}}"#)
        let card = try McpElicitationCard(request: request)
        guard case .url(let url, let elicitationId) = card.mode else {
            return XCTFail("expected URL mode")
        }
        XCTAssertEqual(url.absoluteString, "https://example.com/auth")
        XCTAssertEqual(elicitationId, "e-1")
        XCTAssertEqual(card.response(action: .accept).action, .accept)
        XCTAssertNil(card.response(action: .decline).content)
        XCTAssertNil(card.response(action: .cancel).content)
    }

    @MainActor
    func testFormSupportsPrimitiveEnumAndArrayMatrix() throws {
        let request = try makeRequest(id: "form-1", params: formParams)
        let card = try McpElicitationCard(request: request)
        guard case .form(let fields) = card.mode else { return XCTFail("expected form") }
        XCTAssertEqual(fields.map(\.name), ["age", "enabled", "name", "region", "tags"])

        let response = try card.accept(drafts: [
            "age": .text("42"),
            "enabled": .boolean(true),
            "name": .text("Ada"),
            "region": .text("eu"),
            "tags": .multiple(["fast", "safe"]),
        ])
        let json = try jsonObject(response)
        XCTAssertEqual(json["action"] as? String, "accept")
        let content = try XCTUnwrap(json["content"] as? [String: Any])
        XCTAssertEqual(content["age"] as? Int, 42)
        XCTAssertEqual(content["enabled"] as? Bool, true)
        XCTAssertEqual(content["name"] as? String, "Ada")
        XCTAssertEqual(content["region"] as? String, "eu")
        XCTAssertEqual(content["tags"] as? [String], ["fast", "safe"])
    }

    @MainActor
    func testFormValidationRejectsMissingBoundsAndUnknownSchema() throws {
        let card = try McpElicitationCard(request: makeRequest(id: "form-2", params: formParams))
        XCTAssertThrowsError(try card.accept(drafts: [
            "age": .text("12.5"),
            "enabled": .boolean(false),
            "name": .text("A"),
            "region": .text("invalid"),
            "tags": .multiple([]),
        ]))

        let unsupported = #"{"threadId":"t","turnId":"turn","serverName":"x","mode":"form","message":"Nested","requestedSchema":{"type":"object","properties":{"nested":{"type":"object","properties":{}}},"required":["nested"]}}"#
        XCTAssertThrowsError(try McpElicitationCard(request: makeRequest(id: "bad", params: unsupported)))
    }

    @MainActor
    func testStoreDeclineAndDisconnectAreFailClosed() async throws {
        let store = McpElicitationStore()
        var responses: [McpServerElicitationRequestResponse] = []
        store.resolver = { _, response in responses.append(response); return true }
        try store.handle(request: makeRequest(id: "decline", params: formParams))
        let card = try XCTUnwrap(store.cards.first)
        store.handleConnectionLost()
        XCTAssertTrue(store.cards[0].awaitingRecovery)
        XCTAssertTrue(responses.isEmpty)

        try store.handle(request: makeRequest(id: "decline", params: formParams))
        let refreshed = try XCTUnwrap(store.cards.first)
        let delivered = await store.resolve(card: refreshed, action: .decline)
        XCTAssertTrue(delivered)
        XCTAssertEqual(responses.map(\.action), [.decline])
    }

    private let formParams = #"{"threadId":"t","turnId":"turn","serverName":"forms","mode":"form","message":"Configure","requestedSchema":{"type":"object","properties":{"name":{"type":"string","title":"Name","minLength":2,"maxLength":20},"age":{"type":"integer","title":"Age","minimum":18,"maximum":120},"enabled":{"type":"boolean","title":"Enabled","default":true},"region":{"type":"string","title":"Region","oneOf":[{"const":"us","title":"US"},{"const":"eu","title":"EU"}]},"tags":{"type":"array","title":"Tags","items":{"type":"string","enum":["fast","safe","small"]},"minItems":1,"maxItems":2}},"required":["name","age","enabled","region","tags"]},"_meta":null}"#

    private func makeRequest(id: String, params: String) throws -> JSONRPCRequest {
        let paramsObject = try JSONSerialization.jsonObject(with: Data(params.utf8))
        let data = try JSONSerialization.data(withJSONObject: [
            "id": id,
            "method": ServerRequestMethod.mcpElicitation,
            "params": paramsObject,
        ])
        guard case .request(let request) = try JSONDecoder().decode(JSONRPCMessage.self, from: data) else {
            throw TestError.notRequest
        }
        return request
    }

    private func jsonObject(_ response: McpServerElicitationRequestResponse) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? [String: Any])
    }

    private enum TestError: Error { case notRequest }
}
