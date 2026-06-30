import Testing
import Foundation
@testable import CodexRemote

struct EnvironmentPanelTests {
    private func decode<T: Decodable>(_ t: T.Type, _ j: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(j.utf8))
    }

    @Test func methodConstants() {
        #expect(RPCMethod.accountRead == "account/read")
        #expect(RPCMethod.accountUsageRead == "account/usage/read")
        #expect(RPCMethod.accountRateLimitsRead == "account/rateLimits/read")
        #expect(RPCMethod.configRead == "config/read")
        #expect(RPCMethod.configValueWrite == "config/value/write")
        #expect(ServerNotificationMethod.accountUpdated == "account/updated")
        #expect(ServerNotificationMethod.accountRateLimitsUpdated == "account/rateLimits/updated")
    }
}
