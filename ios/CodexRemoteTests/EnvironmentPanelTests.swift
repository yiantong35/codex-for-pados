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

    // MARK: - Task 2: 账户/用量/速率解码

    @Test func decodeAccountChatgpt() throws {
        let r = try decode(GetAccountResponse.self,
            #"{"account":{"type":"chatgpt","email":"a@b.com","planType":"plus"},"requiresOpenaiAuth":false}"#)
        #expect(r.account == .chatgpt(email: "a@b.com", planType: "plus"))
        #expect(r.requiresOpenaiAuth == false)
    }
    @Test func decodeAccountApiKeyAndNil() throws {
        #expect(try decode(GetAccountResponse.self, #"{"account":{"type":"apiKey"},"requiresOpenaiAuth":true}"#).account == .apiKey)
        #expect(try decode(GetAccountResponse.self, #"{"account":null,"requiresOpenaiAuth":true}"#).account == nil)
    }
    @Test func decodeUsageSummary() throws {
        let r = try decode(GetAccountTokenUsageResponse.self,
            #"{"summary":{"lifetimeTokens":1000,"peakDailyTokens":200,"longestRunningTurnSec":30,"currentStreakDays":3,"longestStreakDays":5}}"#)
        #expect(r.summary.lifetimeTokens == 1000)
        #expect(r.summary.currentStreakDays == 3)
    }
    @Test func decodeRateLimits() throws {
        let r = try decode(GetAccountRateLimitsResponse.self,
            #"{"rateLimits":{"limitId":"codex","primary":{"usedPercent":42.5,"windowDurationMins":300,"resetsAt":1700000000}}}"#)
        #expect(r.rateLimits.primary?.usedPercent == 42.5)
        #expect(r.rateLimits.primary?.resetsAt == 1700000000)
    }
}
