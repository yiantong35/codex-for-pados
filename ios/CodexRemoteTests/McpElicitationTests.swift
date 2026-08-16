import XCTest
@testable import CodexRemote

final class McpElicitationTests: XCTestCase {
    func testURLPresentationShowsOriginAndCompleteNormalizedTarget() throws {
        let url = try XCTUnwrap(URL(string: "HTTPS://Example.COM/oauth/authorize?client_id=ipad&redirect_uri=https%3A%2F%2Fevil.test%2Fcallback#consent"))
        let presentation = McpURLPresentation(url: url)

        XCTAssertEqual(presentation.origin, "https://example.com")
        XCTAssertTrue(presentation.completeURL.contains("/oauth/authorize"))
        XCTAssertTrue(presentation.completeURL.contains("client_id=ipad"))
        XCTAssertTrue(presentation.completeURL.contains("redirect_uri="))
        XCTAssertTrue(presentation.completeURL.hasSuffix("#consent"))
        XCTAssertEqual(presentation.risk, nil)
        XCTAssertTrue(presentation.isAllowed)
    }

    func testURLPresentationRejectsHTTPPunycodeAndUnsupportedSchemes() throws {
        XCTAssertEqual(
            McpURLPresentation(url: try XCTUnwrap(URL(string: "http://example.com/pay"))).risk,
            .insecureHTTP
        )
        XCTAssertEqual(
            McpURLPresentation(url: try XCTUnwrap(URL(string: "https://xn--pple-43d.com/oauth"))).risk,
            .punycodeHost
        )
        XCTAssertEqual(
            McpURLPresentation(url: try XCTUnwrap(URL(string: "custom://example.com/open"))).risk,
            .unsupportedScheme
        )
    }

    func testURLPresentationAllowsXnTextOutsideHost() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/xn--callback?state=xn--token"))
        let presentation = McpURLPresentation(url: url)
        XCTAssertNil(presentation.risk)
        XCTAssertTrue(presentation.isAllowed)
    }

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

        let unsupported = #"{"threadId":"t","turnId":"turn","serverName":"x","mode":"form","message":"Nested","requestedSchema":{"type":"object","properties":{"nested":{"type":"null"}},"required":["nested"]}}"#
        XCTAssertThrowsError(try McpElicitationCard(request: makeRequest(id: "bad", params: unsupported)))
    }

    @MainActor
    func testFormValidationReportsErrorsByField() throws {
        let card = try McpElicitationCard(request: makeRequest(id: "errors", params: formParams))
        let errors = card.validationErrors(drafts: [
            "age": .text("12.5"),
            "enabled": .boolean(false),
            "name": .text("A"),
            "region": .text("invalid"),
            "tags": .multiple([]),
        ])

        XCTAssertEqual(Set(errors.keys), ["age", "name", "region", "tags"])
        XCTAssertEqual(errors["name"], .invalidValue("name"))
    }

    func testFormRejectsExcessiveStructureLongStringsAndDuplicateOptionValues() throws {
        let fields = Dictionary(uniqueKeysWithValues: (0...McpElicitationLimits.maximumFields).map {
            ("field-\($0)", ["type": "boolean"] as [String: Any])
        })
        XCTAssertThrowsError(try McpElicitationCard(request: makeRequest(
            id: "too-many-fields", paramsObject: formParams(properties: fields)
        )))

        let excessiveOptions = (0...McpElicitationLimits.maximumOptionsPerField).map { "option-\($0)" }
        XCTAssertThrowsError(try McpElicitationCard(request: makeRequest(
            id: "too-many-options",
            paramsObject: formParams(properties: ["choice": ["type": "string", "enum": excessiveOptions]])
        )))

        XCTAssertThrowsError(try McpElicitationCard(request: makeRequest(
            id: "duplicate-options",
            paramsObject: formParams(properties: ["choice": ["type": "string", "enum": ["same", "same"]]])
        )))

        XCTAssertThrowsError(try McpElicitationCard(request: makeRequest(
            id: "long-title",
            paramsObject: formParams(properties: [
                "choice": ["type": "string",
                           "title": String(repeating: "x", count: McpElicitationLimits.maximumTitleBytes + 1)],
            ])
        )))
    }

    func testInputBudgetPreservesOriginalAndReportsOverflow() {
        XCTAssertTrue(McpElicitationLimits.inputIsTooLarge(String(repeating: "界", count: 10), maxLength: 3))
        XCTAssertTrue(McpElicitationLimits.inputIsTooLarge(String(repeating: "a", count: 8_000)))
        XCTAssertFalse(McpElicitationLimits.inputIsTooLarge("界界", maxLength: 3))
    }

    func testObjectFieldAcceptsJSONAndReturnsObject() throws {
        let card = try McpElicitationCard(request: makeRequest(id: "object", paramsObject: formParams(properties: [
            "config": ["type": "object", "properties": ["enabled": ["type": "boolean"]]]
        ])))
        let response = try card.accept(drafts: ["config": .text("{\"enabled\":true}")])
        let content = try XCTUnwrap(try jsonObject(response)["content"] as? [String: Any])
        XCTAssertEqual((content["config"] as? [String: Any])?["enabled"] as? Bool, true)
    }

    func testObjectFieldValidatesNestedRequiredFieldsAndTypes() throws {
        let card = try McpElicitationCard(request: makeRequest(id: "nested-object", paramsObject: formParams(properties: [
            "config": [
                "type": "object",
                "properties": [
                    "enabled": ["type": "boolean"],
                    "limits": [
                        "type": "object",
                        "properties": ["retries": ["type": "integer"]],
                        "required": ["retries"],
                    ],
                ],
                "required": ["enabled", "limits"],
            ],
        ])))

        XCTAssertTrue(card.isSubmittable(drafts: [
            "config": .text(#"{"enabled":true,"limits":{"retries":3}}"#),
        ]))
        XCTAssertFalse(card.isSubmittable(drafts: [
            "config": .text(#"{"enabled":"yes","limits":{"retries":3}}"#),
        ]))
        XCTAssertFalse(card.isSubmittable(drafts: [
            "config": .text(#"{"enabled":true,"limits":{}}"#),
        ]))
        XCTAssertEqual(
            card.validationErrors(drafts: ["config": .text(#"{"enabled":true,"limits":{}}"#)])["config"],
            .invalidValue("config")
        )
    }

    @MainActor
    func testLocalizedNegativeDecimalIsAcceptedAndSerializedAsNumber() throws {
        let params = formParams(properties: [
            "temperature": ["type": "number", "minimum": -10, "maximum": 10],
        ])
        let card = try McpElicitationCard(request: makeRequest(id: "localized-number", paramsObject: params))

        let response = try card.accept(
            drafts: ["temperature": .text("-1,5")],
            locale: Locale(identifier: "fr_FR")
        )
        let content = try XCTUnwrap(try jsonObject(response)["content"] as? [String: Any])
        XCTAssertEqual(content["temperature"] as? Double, -1.5)
    }

    @MainActor
    func testStoreDeclineAndDisconnectAreFailClosed() async throws {
        let store = McpElicitationStore()
        var responses: [McpServerElicitationRequestResponse] = []
        store.resolver = { _, response in responses.append(response); return true }
        try store.handle(request: makeRequest(id: "decline", params: formParams))
        store.handleConnectionLost()
        XCTAssertTrue(store.cards[0].awaitingRecovery)
        XCTAssertTrue(responses.isEmpty)

        try store.handle(request: makeRequest(id: "decline", params: formParams))
        let refreshed = try XCTUnwrap(store.cards.first)
        let delivered = await store.resolve(card: refreshed, action: .decline)
        XCTAssertTrue(delivered)
        XCTAssertEqual(responses.map(\.action), [.decline])
    }

    @MainActor
    func testFailedDecisionIsVisibleAndCanRetry() async throws {
        let store = McpElicitationStore()
        var attempts = 0
        store.resolver = { _, _ in attempts += 1; return attempts == 2 }
        try store.handle(request: makeRequest(id: "retry", params: formParams))
        let card = try XCTUnwrap(store.cards.first)

        let first = await store.resolve(card: card, action: .decline)
        XCTAssertFalse(first)
        XCTAssertEqual(store.submissionState(for: card.id), .failed)
        let second = await store.resolve(card: card, action: .decline)
        XCTAssertTrue(second)
        XCTAssertTrue(store.cards.isEmpty)
    }

    @MainActor
    func testUnreplayedRequestExpiresAndCanBeDismissed() throws {
        let store = McpElicitationStore()
        try store.handle(request: makeRequest(id: "expired", params: formParams))
        store.handleConnectionLost()
        store.expireAwaitingRecovery()
        XCTAssertTrue(store.expiredRecoveryIds.contains(.string("expired")))
        XCTAssertFalse(store.cards[0].awaitingRecovery)
        store.discardExpired(.string("expired"))
        XCTAssertTrue(store.cards.isEmpty)
    }

    private let formParams = #"{"threadId":"t","turnId":"turn","serverName":"forms","mode":"form","message":"Configure","requestedSchema":{"type":"object","properties":{"name":{"type":"string","title":"Name","minLength":2,"maxLength":20},"age":{"type":"integer","title":"Age","minimum":18,"maximum":120},"enabled":{"type":"boolean","title":"Enabled","default":true},"region":{"type":"string","title":"Region","oneOf":[{"const":"us","title":"US"},{"const":"eu","title":"EU"}]},"tags":{"type":"array","title":"Tags","items":{"type":"string","enum":["fast","safe","small"]},"minItems":1,"maxItems":2}},"required":["name","age","enabled","region","tags"]},"_meta":null}"#

    private func makeRequest(id: String, params: String) throws -> JSONRPCRequest {
        let paramsObject = try JSONSerialization.jsonObject(with: Data(params.utf8))
        return try makeRequest(id: id, paramsObject: paramsObject)
    }

    private func makeRequest(id: String, paramsObject: Any) throws -> JSONRPCRequest {
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

    private func formParams(properties: [String: Any]) -> [String: Any] {
        [
            "threadId": "t", "turnId": "turn", "serverName": "forms",
            "mode": "form", "message": "Configure",
            "requestedSchema": ["type": "object", "properties": properties, "required": []],
        ]
    }

    private func jsonObject(_ response: McpServerElicitationRequestResponse) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? [String: Any])
    }

    private enum TestError: Error { case notRequest }
}
