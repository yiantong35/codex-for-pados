import Foundation

/// 会话内的一条可渲染项。随流式事件累加（agent 正文 / 命令输出）。
enum ConversationItem: Identifiable, Equatable {
    case userMessage(id: String, text: String)
    case agentMessage(id: String, text: String)              // 随 delta 累加
    case commandExecution(id: String, command: String, output: String, finished: Bool)
    case fileChange(id: String, file: String, added: Int, removed: Int, diff: String)

    var id: String {
        switch self {
        case .userMessage(let i, _), .agentMessage(let i, _),
             .commandExecution(let i, _, _, _), .fileChange(let i, _, _, _, _): return i
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
}
