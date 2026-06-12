import XCTest
@testable import CodexRemote

final class ProtocolTypesTests: XCTestCase {
    func testV2AcceptWithAmendmentEncodes() throws {
        let d = CommandExecutionApprovalDecision
            .acceptWithExecpolicyAmendment(execpolicyAmendment: ["git", "status"])
        let data = try JSONEncoder().encode(CommandExecutionApprovalResponse(decision: d))
        let s = String(data: data, encoding: .utf8)!
        XCTAssertTrue(s.contains("acceptWithExecpolicyAmendment"))
        XCTAssertTrue(s.contains("execpolicy_amendment"))
    }
    func testV2DeclineEncodesBareString() throws {
        let data = try JSONEncoder().encode(CommandExecutionApprovalResponse(decision: .decline))
        XCTAssertEqual(String(data: data, encoding: .utf8), #"{"decision":"decline"}"#)
    }
    func testLegacyReviewDecisionApprovedForSession() throws {
        let data = try JSONEncoder().encode(ExecCommandApprovalResponse(decision: .approvedForSession))
        XCTAssertEqual(String(data: data, encoding: .utf8), #"{"decision":"approved_for_session"}"#)
    }
    func testUserInputTextEncodesElements() throws {
        let data = try JSONEncoder().encode([UserInput.text("hi")])
        let s = String(data: data, encoding: .utf8)!
        XCTAssertTrue(s.contains(#""type":"text""#))
        XCTAssertTrue(s.contains("text_elements"))
    }
    func testTurnStartParamsUsesEffortKey() throws {
        let p = TurnStartParams(threadId: "t1", input: [.text("hi")],
                                model: "gpt-5", effort: .high, cwd: nil)
        let s = String(data: try JSONEncoder().encode(p), encoding: .utf8)!
        XCTAssertTrue(s.contains(#""effort":"high""#))
    }
    func testInitializeResponseDecodes() throws {
        let json = #"{"userAgent":"codex","codexHome":"/Users/x/.codex","platformFamily":"unix","platformOs":"macos"}"#
        let r = try JSONDecoder().decode(InitializeResponse.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(r.platformOs, "macos")
    }
    func testThreadListResponseDecodesRealThreadSubset() throws {
        let json = #"""
        {"data":[{"id":"t1","sessionId":"s1","forkedFromId":null,"preview":"hello","ephemeral":false,"modelProvider":"openai","createdAt":1700000000.0,"updatedAt":1700000100.0,"status":{"kind":"idle"},"path":null,"cwd":"/Users/x/proj","cliVersion":"0.1.0","source":{"kind":"cli"},"threadSource":null,"agentNickname":null,"agentRole":null,"gitInfo":null,"name":"My Thread","turns":[]}],"nextCursor":"c2","backwardsCursor":null}
        """#
        let r = try JSONDecoder().decode(ThreadListResponse.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(r.data.count, 1)
        XCTAssertEqual(r.data[0].id, "t1")
        XCTAssertEqual(r.data[0].preview, "hello")
        XCTAssertEqual(r.data[0].cwd, "/Users/x/proj")
        XCTAssertEqual(r.data[0].name, "My Thread")
        XCTAssertEqual(r.data[0].updatedAt, 1700000100.0)
        XCTAssertEqual(r.nextCursor, "c2")
    }
    func test_threadSummary_decodes_gitInfo() throws {
        let json = """
        {"id":"t1","sessionId":"s1","preview":"p","modelProvider":"openai",
         "createdAt":1,"updatedAt":2,"cwd":"/repo/web-dev","cliVersion":"0.133.0","name":null,
         "gitInfo":{"sha":"abc","branch":"main","originUrl":"git@github.com:me/web-dev.git"}}
        """.data(using: .utf8)!
        let t = try JSONDecoder().decode(ThreadSummary.self, from: json)
        XCTAssertEqual(t.gitInfo?.originUrl, "git@github.com:me/web-dev.git")
        XCTAssertEqual(t.gitInfo?.branch, "main")
    }

    func test_threadSummary_decodes_nil_gitInfo() throws {
        let json = """
        {"id":"t2","sessionId":"s2","preview":"p","modelProvider":"openai",
         "createdAt":1,"updatedAt":2,"cwd":"/Volumes/mount","cliVersion":"0.133.0","name":null,"gitInfo":null}
        """.data(using: .utf8)!
        let t = try JSONDecoder().decode(ThreadSummary.self, from: json)
        XCTAssertNil(t.gitInfo)
    }
}
