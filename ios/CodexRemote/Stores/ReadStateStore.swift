import Foundation
import Observation

/// 客户端自建未读追踪（设计 D4）。两份本地持久化 map：
///   - viewedAt:    [threadId: Double]   上次查看时的 updatedAt
///   - lastOutcome: [threadId: Outcome]  上次 turn 结局（turn/completed 时写入）
/// 未读判定（B9）：`thread.updatedAt > viewedAt[id]`（严格大于）。
/// 首次为空（B2）：viewedAt(id) 返回 .infinity，使任何 outcome 都不算未读 → 全部已读。
@Observable
@MainActor
final class ReadStateStore {
    private let defaults: UserDefaults
    private static let viewedKey = "sidebar.readstate.viewedAt"
    private static let outcomeKey = "sidebar.readstate.lastOutcome"

    private var viewedAtMap: [String: Double]
    private var lastOutcomeMap: [String: String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.viewedAtMap = (defaults.dictionary(forKey: Self.viewedKey) as? [String: Double]) ?? [:]
        self.lastOutcomeMap = (defaults.dictionary(forKey: Self.outcomeKey) as? [String: String]) ?? [:]
    }

    /// 未记录过 → .infinity（B2：updatedAt > .infinity 恒 false → 视为已读）。
    func viewedAt(_ threadId: String) -> Double {
        viewedAtMap[threadId] ?? .infinity
    }

    func lastOutcome(_ threadId: String) -> Outcome? {
        lastOutcomeMap[threadId].flatMap(Outcome.init(rawValue:))
    }

    /// 点击选中会话时调用：记录当前 updatedAt 为已查看（设计 D4，B3/B4）。
    func markViewed(_ threadId: String, updatedAt: Double) {
        viewedAtMap[threadId] = updatedAt
        defaults.set(viewedAtMap, forKey: Self.viewedKey)
    }

    /// turn/completed 时调用：持久化上次结局（B8 覆盖、结局色跨重启准确）。
    func recordOutcome(_ threadId: String, outcome: Outcome) {
        lastOutcomeMap[threadId] = outcome.rawValue
        defaults.set(lastOutcomeMap, forKey: Self.outcomeKey)
    }
}
