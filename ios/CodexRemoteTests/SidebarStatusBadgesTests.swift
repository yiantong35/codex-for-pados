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
}
