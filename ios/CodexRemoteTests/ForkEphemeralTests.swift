import Testing
import Foundation
@testable import CodexRemote

struct ForkEphemeralTests {
    @Test func encodesEphemeralTrue() throws {
        let params = ThreadForkParams(threadId: "t1", ephemeral: true)
        let json = String(decoding: try JSONEncoder().encode(params), as: UTF8.self)
        #expect(json.contains("\"threadId\":\"t1\""))
        #expect(json.contains("\"ephemeral\":true"))
    }
    @Test func omitsEphemeralWhenNil() throws {
        let params = ThreadForkParams(threadId: "t1", ephemeral: nil)
        let json = String(decoding: try JSONEncoder().encode(params), as: UTF8.self)
        #expect(!json.contains("ephemeral"))
    }
    @Test func decodesForkedFromId() throws {
        let respJSON = #"{"thread":{"id":"fork-1","forkedFromId":"t1","ephemeral":true}}"#
        let decoded = try JSONDecoder().decode(ForkedThreadResponse.self, from: Data(respJSON.utf8))
        #expect(decoded.thread.id == "fork-1")
        #expect(decoded.thread.forkedFromId == "t1")
    }
}
