import Foundation

/// plan 步骤状态（对齐 codex turn/plan/updated 的 step.status）。
/// 真实取值含下划线形态 "in_progress"，另兼容驼峰 "inProgress" 容错。
enum TurnPlanStepStatus: String, Equatable {
    case pending
    case inProgress = "in_progress"
    case completed

    /// 从任意 JSON 值容错解析；缺省 / 未知 → pending（不崩溃）。
    static func from(any: Any?) -> TurnPlanStepStatus {
        guard let s = any as? String else { return .pending }
        switch s {
        case "pending": return .pending
        case "in_progress", "inProgress": return .inProgress
        case "completed", "complete": return .completed
        default: return .pending
        }
    }
}

/// 单条 plan 步骤（摘要「进度」P0 数据）。
struct TurnPlanStep: Equatable {
    var step: String
    var status: TurnPlanStepStatus
}
