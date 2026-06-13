import Foundation

/// 命令执行状态（对齐 codex CommandExecutionStatus，见 realTurnSequence.json item.status）。
enum CommandStatus: String, Equatable {
    case inProgress    // 运行中
    case completed     // 成功完成
    case failed        // 非零退出
    case declined      // 被拒绝执行

    /// 命令是否已结束（非运行中）。便于 UI 决定显示转圈还是终态徽标。
    var isFinished: Bool { self != .inProgress }
}

/// 会话内的一条可渲染项。随流式事件累加（agent 正文 / 命令输出）。
enum ConversationItem: Identifiable, Equatable {
    case userMessage(id: String, text: String)
    case agentMessage(id: String, text: String)              // 随 delta 累加
    case commandExecution(id: String, command: String, output: String,
                          status: CommandStatus, exitCode: Int?, durationMs: Int?)
    case fileChange(id: String, file: String, added: Int, removed: Int, diff: String)

    var id: String {
        switch self {
        case .userMessage(let i, _), .agentMessage(let i, _),
             .commandExecution(let i, _, _, _, _, _), .fileChange(let i, _, _, _, _): return i
        }
    }
}

/// 单个会话（thread）的归约状态。
struct ConversationState: Equatable {
    var threadId: String
    var items: [ConversationItem] = []
    var activeTurnId: String?
    var activeTurnKind: NonSteerableTurnKind?    // 非 nil 表示当前 turn 不可 steer
    var isTurnRunning: Bool { activeTurnId != nil }

    /// 本会话执行过的命令条数（纯派生，用于「已运行 N 条命令」汇总）。
    var commandCount: Int {
        items.reduce(0) { count, item in
            if case .commandExecution = item { return count + 1 }
            return count
        }
    }
}
