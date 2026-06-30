import Foundation

// MARK: - 账户（批次④ 环境面板）

/// protocol v2 Account（tagged）。planType 以 String 容纳（PlanType 枚举字符串值）。
enum Account: Equatable {
    case apiKey
    case chatgpt(email: String, planType: String)
    case amazonBedrock
}

extension Account: Decodable {
    private enum K: String, CodingKey { case type, email, planType }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        switch try c.decode(String.self, forKey: .type) {
        case "chatgpt":
            self = .chatgpt(email: (try? c.decode(String.self, forKey: .email)) ?? "",
                            planType: (try? c.decode(String.self, forKey: .planType)) ?? "")
        case "amazonBedrock": self = .amazonBedrock
        default: self = .apiKey   // apiKey + 未知兜底
        }
    }
}

struct GetAccountResponse: Decodable {
    let account: Account?
    let requiresOpenaiAuth: Bool
}

/// bigint 字段以 Int? 解码（JSON number）；缺失/类型异常容忍为 nil。
struct AccountTokenUsageSummary: Decodable, Equatable {
    var lifetimeTokens: Int?
    var peakDailyTokens: Int?
    var longestRunningTurnSec: Int?
    var currentStreakDays: Int?
    var longestStreakDays: Int?
}

struct GetAccountTokenUsageResponse: Decodable {
    let summary: AccountTokenUsageSummary
    // dailyUsageBuckets 忽略
}

struct RateLimitWindow: Decodable, Equatable {
    let usedPercent: Double
    var windowDurationMins: Double?
    var resetsAt: Double?      // unix 秒
}

struct RateLimitSnapshot: Decodable, Equatable {
    var limitId: String?
    var limitName: String?
    var primary: RateLimitWindow?
    var secondary: RateLimitWindow?
    // credits/individualLimit/planType/rateLimitReachedType 忽略
}

struct GetAccountRateLimitsResponse: Decodable {
    let rateLimits: RateLimitSnapshot
    // rateLimitsByLimitId 忽略
}

// MARK: - 配置（curated 子集）

/// approval_policy：字符串简单态 或 granular 对象（对象态只读）。
enum ApprovalPolicyValue: Equatable {
    case simple(String)   // untrusted/on-failure/on-request/never
    case granular         // 对象态，移动端只读不编辑
}

extension ApprovalPolicyValue: Decodable {
    init(from d: Decoder) throws {
        let c = try d.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .simple(s) }
        else { self = .granular }   // 对象/其它 → granular 只读
    }
}

/// 仅 curated 子集；其余 Config 字段宽容忽略。
struct CuratedConfig: Decodable {
    var model: String?
    var approvalPolicy: ApprovalPolicyValue?
    var sandboxMode: String?
    var modelReasoningEffort: String?
    var modelReasoningSummary: String?
    var modelVerbosity: String?
    var webSearch: AnyCodable?     // WebSearchMode：字符串或对象，原样持有用于展示

    enum CodingKeys: String, CodingKey {
        case model
        case approvalPolicy = "approval_policy"
        case sandboxMode = "sandbox_mode"
        case modelReasoningEffort = "model_reasoning_effort"
        case modelReasoningSummary = "model_reasoning_summary"
        case modelVerbosity = "model_verbosity"
        case webSearch = "web_search"
    }
}

extension CuratedConfig: Equatable {
    static func == (l: CuratedConfig, r: CuratedConfig) -> Bool {
        l.model == r.model && l.approvalPolicy == r.approvalPolicy && l.sandboxMode == r.sandboxMode
            && l.modelReasoningEffort == r.modelReasoningEffort && l.modelReasoningSummary == r.modelReasoningSummary
            && l.modelVerbosity == r.modelVerbosity
    }
}

struct ConfigReadResponse: Decodable {
    let config: CuratedConfig
    // origins / layers 忽略
}

/// config/value/write 参数。value 用 AnyCodable 容纳任意 JsonValue。
struct ConfigValueWriteParams: Encodable {
    let keyPath: String
    let value: AnyCodable
    let mergeStrategy: String   // "replace" | "upsert"
}

// MARK: - 模型（model/list）

/// protocol v2 Model 子集（MVP 仅取展示所需）。
struct ModelSummary: Decodable, Equatable {
    let id: String
    var displayName: String?
    var hidden: Bool = false
    enum CodingKeys: String, CodingKey { case id, displayName, hidden }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        displayName = try? c.decode(String.self, forKey: .displayName)
        hidden = (try? c.decode(Bool.self, forKey: .hidden)) ?? false
    }
}

/// model/list 响应：data + nextCursor（cursor 忽略，MVP 取首页）。
struct ModelListResponse: Decodable {
    let data: [ModelSummary]
    var nextCursor: String?
}


