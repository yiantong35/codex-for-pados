import XCTest
@testable import CodexRemote

final class ServerRequestRouterTests: XCTestCase {
    func testEveryGeneratedMethodHasAnExplicitOutcome() {
        let expected: [String: ServerRequestOutcome] = [
            ServerRequestMethod.cmdApprovalV2: .deferred(.approval),
            ServerRequestMethod.fileApprovalV2: .deferred(.approval),
            ServerRequestMethod.userInput: .deferred(.userInput),
            ServerRequestMethod.mcpElicitation: .deferred(.mcpElicitation),
            ServerRequestMethod.permsApprovalV2: .deferred(.approval),
            ServerRequestMethod.dynamicToolCall: .methodNotSupported,
            ServerRequestMethod.authTokensRefresh: .methodNotSupported,
            ServerRequestMethod.attestationGenerate: .methodNotSupported,
            ServerRequestMethod.applyPatchApprovalLegacy: .deferred(.approval),
            ServerRequestMethod.execApprovalLegacy: .deferred(.approval),
        ]

        XCTAssertEqual(Set(expected.keys), Set(ServerRequestMethod.generatedMethods))
        for (method, outcome) in expected {
            XCTAssertEqual(ServerRequestRouter.outcome(for: method), outcome, method)
        }
    }

    func testUnsupportedAndUnknownMethodsGetMethodNotFoundErrors() async throws {
        let mock = MockTransport()
        let client = JSONRPCClient(transport: mock)
        await client.start()

        let methods = [
            ServerRequestMethod.dynamicToolCall,
            ServerRequestMethod.authTokensRefresh,
            ServerRequestMethod.attestationGenerate,
            "future/method",
        ]
        for (index, method) in methods.enumerated() {
            await mock.feed(#"{"id":"unsupported-\#(index)","method":"\#(method)","params":{}}"#)
        }

        let responses = try await waitForSentFrames(mock, count: methods.count)
        for (index, response) in responses.enumerated() {
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
            XCTAssertEqual(json["id"] as? String, "unsupported-\(index)")
            let error = try XCTUnwrap(json["error"] as? [String: Any])
            XCTAssertEqual(error["code"] as? Int, -32601)
        }
    }

    func testDeferredRequestsOnlyReachTheirOwnerAndCompleteOnce() async throws {
        let mock = MockTransport()
        let client = JSONRPCClient(transport: mock)
        let approvals = await client.serverRequests(for: .approval)
        let userInputs = await client.serverRequests(for: .userInput)
        await client.start()

        let approval = Task { await approvals.first(where: { _ in true }) }
        let userInput = Task { await userInputs.first(where: { _ in true }) }
        await mock.feed(#"{"id":"approval-1","method":"item/commandExecution/requestApproval","params":{}}"#)
        let receivedApproval = await approval.value
        let request = try XCTUnwrap(receivedApproval)
        XCTAssertEqual(request.id, .string("approval-1"))

        let delivered = try await client.respond(to: request.id, result: AnyCodable(["decision": "decline"]))
        let duplicate = try await client.respond(to: request.id, result: AnyCodable(["decision": "accept"]))
        XCTAssertTrue(delivered)
        XCTAssertFalse(duplicate)
        let sentCount = await mock.sent.count
        XCTAssertEqual(sentCount, 1)
        userInput.cancel()
    }

    func testInteractiveMethodsAreIsolatedByOwner() async throws {
        let mock = MockTransport()
        let client = JSONRPCClient(transport: mock)
        let approvals = await client.serverRequests(for: .approval)
        let userInputs = await client.serverRequests(for: .userInput)
        let elicitations = await client.serverRequests(for: .mcpElicitation)
        await client.start()

        let approval = Task { await approvals.first(where: { _ in true }) }
        let userInput = Task { await userInputs.first(where: { _ in true }) }
        let elicitation = Task { await elicitations.first(where: { _ in true }) }
        await mock.feed(lines: [
            #"{"id":"a","method":"item/fileChange/requestApproval","params":{}}"#,
            #"{"id":"u","method":"item/tool/requestUserInput","params":{}}"#,
            #"{"id":"m","method":"mcpServer/elicitation/request","params":{}}"#,
        ])

        let approvalRequest = await approval.value
        let userInputRequest = await userInput.value
        let elicitationRequest = await elicitation.value
        XCTAssertEqual(approvalRequest?.id, .string("a"))
        XCTAssertEqual(userInputRequest?.id, .string("u"))
        XCTAssertEqual(elicitationRequest?.id, .string("m"))
    }

    func testDeferredRequestIsDeliveredWhenOwnerSubscribesAfterArrival() async throws {
        let mock = MockTransport()
        let client = JSONRPCClient(transport: mock)
        await client.start()
        await mock.feed(#"{"id":"early","method":"item/permissions/requestApproval","params":{}}"#)

        var deferredCount = 0
        for _ in 0..<200 {
            deferredCount = await client.deferredServerRequestCount()
            if deferredCount == 1 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        guard deferredCount == 1 else {
            XCTFail("request was not routed before subscription")
            return
        }
        let approvals = await client.serverRequests(for: .approval)
        let received = await approvals.first(where: { _ in true })

        XCTAssertEqual(received?.id, .string("early"))
    }

    func testDisconnectInvalidatesDeferredRequestOwnership() async throws {
        let mock = MockTransport()
        let client = JSONRPCClient(transport: mock)
        let approvals = await client.serverRequests(for: .approval)
        await client.start()

        let approval = Task { await approvals.first(where: { _ in true }) }
        await mock.feed(#"{"id":"approval-2","method":"item/fileChange/requestApproval","params":{}}"#)
        let receivedApproval = await approval.value
        let request = try XCTUnwrap(receivedApproval)
        await mock.close()
        await client.failInflight(TransportError.channelClosed(reason: "drop"))

        let delivered = try await client.respond(to: request.id, result: AnyCodable(["decision": "decline"]))
        XCTAssertFalse(delivered)
        let sentIsEmpty = await mock.sent.isEmpty
        XCTAssertTrue(sentIsEmpty)
    }

    func testDeferredErrorAndExternalResolutionEachCompleteOwnershipOnce() async throws {
        let mock = MockTransport()
        let client = JSONRPCClient(transport: mock)
        let elicitations = await client.serverRequests(for: .mcpElicitation)
        await client.start()

        let first = Task { await elicitations.first(where: { _ in true }) }
        await mock.feed(#"{"id":"schema-error","method":"mcpServer/elicitation/request","params":{}}"#)
        let firstRequest = await first.value
        let firstId = try XCTUnwrap(firstRequest?.id)
        let sent = try await client.respond(
            to: firstId,
            error: JSONRPCErrorBody(code: -32602, message: "Unsupported schema")
        )
        let duplicate = try await client.respond(
            to: firstId,
            error: JSONRPCErrorBody(code: -32602, message: "duplicate")
        )
        XCTAssertTrue(sent)
        XCTAssertFalse(duplicate)

        let secondStream = await client.serverRequests(for: .mcpElicitation)
        let second = Task { await secondStream.first(where: { _ in true }) }
        await mock.feed(#"{"id":"resolved-elsewhere","method":"mcpServer/elicitation/request","params":{}}"#)
        let secondRequest = await second.value
        let secondId = try XCTUnwrap(secondRequest?.id)
        await client.discardServerRequest(secondId)
        let late = try await client.respond(to: secondId, result: AnyCodable(["action": "cancel"]))
        XCTAssertFalse(late)
    }

    private func waitForSentFrames(_ mock: MockTransport, count: Int) async throws -> [String] {
        for _ in 0..<200 {
            let frames = await mock.sent
            if frames.count == count { return frames }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("timed out waiting for \(count) responses")
        return []
    }
}
