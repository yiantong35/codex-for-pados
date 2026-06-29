import Testing
import Foundation
@testable import CodexRemote

struct SidebarStatusBadgesTests {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    @Test func methodConstant() {
        #expect(ServerNotificationMethod.threadStatusChanged == "thread/status/changed")
    }

    @Test func decodeActiveWithFlags() throws {
        let s = try decode(ThreadStatus.self, #"{"type":"active","activeFlags":["waitingOnApproval"]}"#)
        #expect(s == .active(activeFlags: [.waitingOnApproval]))
    }

    @Test func decodeActiveEmptyFlags() throws {
        let s = try decode(ThreadStatus.self, #"{"type":"active","activeFlags":[]}"#)
        #expect(s == .active(activeFlags: []))
    }

    @Test func decodeIdleAndSystemError() throws {
        #expect(try decode(ThreadStatus.self, #"{"type":"idle"}"#) == .idle)
        #expect(try decode(ThreadStatus.self, #"{"type":"systemError"}"#) == .systemError)
        #expect(try decode(ThreadStatus.self, #"{"type":"notLoaded"}"#) == .notLoaded)
    }

    @Test func decodeUnknownFlagTolerated() throws {
        let s = try decode(ThreadStatus.self, #"{"type":"active","activeFlags":["waitingOnUserInput","futureFlag"]}"#)
        #expect(s == .active(activeFlags: [.waitingOnUserInput]))
    }

    @Test func decodeStatusChangedNotification() throws {
        let n = try decode(ThreadStatusChangedNotification.self,
            #"{"threadId":"t1","status":{"type":"active","activeFlags":["waitingOnApproval"]}}"#)
        #expect(n.threadId == "t1")
        #expect(n.status == .active(activeFlags: [.waitingOnApproval]))
    }

    // MARK: - Task 2: ThreadSummary.status

    @Test func threadSummaryDecodesStatus() throws {
        let json = #"""
        {"id":"t1","sessionId":"s1","preview":"hi","modelProvider":"openai",
         "createdAt":1.0,"updatedAt":2.0,"cwd":"/x","cliVersion":"0.1",
         "status":{"type":"active","activeFlags":[]}}
        """#
        let t = try decode(ThreadSummary.self, json)
        #expect(t.status == .active(activeFlags: []))
    }

    @Test func threadSummaryStatusOptionalDefaultsNil() throws {
        let json = #"""
        {"id":"t1","sessionId":"s1","preview":"hi","modelProvider":"openai",
         "createdAt":1.0,"updatedAt":2.0,"cwd":"/x","cliVersion":"0.1"}
        """#
        let t = try decode(ThreadSummary.self, json)
        #expect(t.status == nil)
    }

    // MARK: - Task 3: 运行态→徽标映射纯函数

    @Test func runStateBadgeMapping() {
        #expect(RunStateBadge.from(.active(activeFlags: [])) == .running)
        #expect(RunStateBadge.from(.active(activeFlags: [.waitingOnUserInput])) == .waitingInput)
        #expect(RunStateBadge.from(.active(activeFlags: [.waitingOnApproval])) == .waitingApproval)
        // 同时含两 flag：审批优先（更需用户动作）
        #expect(RunStateBadge.from(.active(activeFlags: [.waitingOnUserInput, .waitingOnApproval])) == .waitingApproval)
        #expect(RunStateBadge.from(.systemError) == .error)
        #expect(RunStateBadge.from(.idle) == RunStateBadge.none)
        #expect(RunStateBadge.from(.notLoaded) == RunStateBadge.none)
        #expect(RunStateBadge.from(nil) == RunStateBadge.none)
    }
}
