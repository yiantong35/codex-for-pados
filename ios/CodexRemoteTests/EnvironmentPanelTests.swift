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

    // MARK: - Task 3: 配置 curated 子集 + 写参数

    @Test func decodeCuratedConfig() throws {
        let r = try decode(ConfigReadResponse.self, #"""
        {"config":{"model":"gpt-5","approval_policy":"on-request","sandbox_mode":"workspace-write",
         "model_reasoning_effort":"high","model_verbosity":"low","instructions":"忽略我",
         "tools":{"x":1}},"origins":{},"layers":null}
        """#)
        #expect(r.config.model == "gpt-5")
        #expect(r.config.approvalPolicy == .simple("on-request"))
        #expect(r.config.sandboxMode == "workspace-write")
        #expect(r.config.modelReasoningEffort == "high")
    }
    @Test func decodeGranularApprovalReadOnly() throws {
        let r = try decode(ConfigReadResponse.self,
            #"{"config":{"approval_policy":{"granular":{"rules":true}}},"origins":{}}"#)
        #expect(r.config.approvalPolicy == .granular)   // 对象态 → 只读
    }
    @Test func configWriteParamsShape() throws {
        let p = ConfigValueWriteParams(keyPath: "model", value: AnyCodable("gpt-5"), mergeStrategy: "replace")
        let j = String(decoding: try JSONEncoder().encode(p), as: UTF8.self)
        #expect(j.contains("\"keyPath\":\"model\""))
        #expect(j.contains("\"mergeStrategy\":\"replace\""))
        #expect(j.contains("\"value\":\"gpt-5\""))
    }

    // MARK: - Task 4: EnvironmentStore

    @MainActor @Test func storeConsumesAccountBroadcast() {
        let s = EnvironmentStore()
        s.handleAccountUpdated(.chatgpt(email: "x@y.com", planType: "pro"))
        #expect(s.account == .chatgpt(email: "x@y.com", planType: "pro"))
    }
    @MainActor @Test func storeConsumesRateLimitsBroadcast() {
        let s = EnvironmentStore()
        let snap = RateLimitSnapshot(limitId: "codex", limitName: nil,
                                     primary: RateLimitWindow(usedPercent: 10, windowDurationMins: nil, resetsAt: nil),
                                     secondary: nil)
        s.handleRateLimitsUpdated(snap)
        #expect(s.rateLimits?.primary?.usedPercent == 10)
    }
    @MainActor @Test func modelSwitchParams() {
        let p = EnvironmentStore.modelWriteParams(modelId: "gpt-5")
        #expect(p.keyPath == "model")
        #expect(p.mergeStrategy == "replace")
    }
    @MainActor @Test func configWriteParamsFor() {
        let p = EnvironmentStore.configWriteParams(keyPath: "approval_policy", stringValue: "never")
        #expect(p.keyPath == "approval_policy")
        #expect(p.mergeStrategy == "replace")
    }
}
