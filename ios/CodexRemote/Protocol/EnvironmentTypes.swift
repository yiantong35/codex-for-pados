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
