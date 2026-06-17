import Foundation

/// 摘要浮层 P0 数据的派生纯函数集合（无 SwiftUI 依赖，便于单测）。
/// 数据源：ConversationState（diff 行数 / 命令任务 / plan）+ ThreadSummary（cwd）。
enum WorkspaceSummary {

    /// 全会话 diff 行数汇总（来自所有 .fileChange item 的 added/removed）。
    struct DiffLineCounts: Equatable {
        var added: Int
        var removed: Int
        var changedFiles: Int
        var isEmpty: Bool { changedFiles == 0 }
    }

    /// 全 turn diff 行数汇总：解析聚合 turnDiff（唯一真相源），与进度卡片同源。
    static func diffLineCounts(in state: ConversationState) -> DiffLineCounts {
        let s = TurnDiffStats.parse(state.turnDiff)
        return DiffLineCounts(added: s.added, removed: s.removed, changedFiles: s.changedFiles)
    }

    /// plan 进度：完成数 / 总数 + 步骤明细（直接复用 ConversationState.plan）。
    struct PlanProgress: Equatable {
        var steps: [TurnPlanStep]
        var completed: Int { steps.filter { $0.status == .completed }.count }
        var total: Int { steps.count }
        var isEmpty: Bool { steps.isEmpty }
    }

    static func planProgress(in state: ConversationState) -> PlanProgress {
        PlanProgress(steps: state.plan)
    }

    /// 单条命令任务（摘要「任务」P0）。
    struct CommandTask: Equatable, Identifiable {
        var id: String
        var command: String
        var status: CommandStatus
    }

    /// 会话内所有命令执行项，按出现顺序。
    static func commandTasks(in state: ConversationState) -> [CommandTask] {
        state.items.compactMap { item in
            guard case .commandExecution(let id, let cmd, _, let status, _, _) = item else { return nil }
            return CommandTask(id: id, command: cmd, status: status)
        }
    }
}
