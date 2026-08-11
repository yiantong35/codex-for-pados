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

struct UserMessageAttachment: Equatable {
    enum Kind: Equatable { case image, localImage }

    let kind: Kind
    let source: String
    /// Stable across optimistic and authoritative message IDs within this process.
    let cacheKey: String

    init(kind: Kind, source: String) {
        self.kind = kind
        self.source = source
        var hasher = Hasher()
        hasher.combine(kind == .image ? 1 : 2)
        hasher.combine(source)
        self.cacheKey = "\(source.utf8.count)-\(String(hasher.finalize(), radix: 16))"
    }
}

enum WebSearchAction: Equatable {
    case search(query: String?, queries: [String])
    case openPage(url: String?)
    case findInPage(url: String?, pattern: String?)
    case other

    var detail: String {
        switch self {
        case .search(let query, let queries):
            return ([query].compactMap { $0 } + queries).joined(separator: ", ")
        case .openPage(let url):
            return url ?? ""
        case .findInPage(let url, let pattern):
            return [pattern, url].compactMap { $0 }.joined(separator: " · ")
        case .other:
            return "other"
        }
    }
}

/// 会话内的一条可渲染项。随流式事件累加（agent 正文 / 命令输出）。
/// 会话内的一条可渲染项。随流式事件累加（agent 正文 / 命令输出）。
/// 平铺 18 case：17 种 v2 ThreadItem + unknown 兜底（方案1）。
enum ConversationItem: Identifiable, Equatable {
    case userMessage(id: String, text: String, attachments: [UserMessageAttachment])
    case agentMessage(id: String, text: String)              // 随 delta 累加
    case reasoning(id: String, text: String)                 // 思考/推理：随 delta 累加
    case commandExecution(id: String, command: String, output: String, outputLineCount: Int,
                          status: CommandStatus, exitCode: Int?, durationMs: Int?)
    case fileChange(id: String, file: String, added: Int, removed: Int, diff: String)
    // 新增（v2 协议已探明字段）
    case mcpToolCall(id: String, server: String, tool: String,
                     status: String, result: String, durationMs: Int?)
    case dynamicToolCall(id: String, namespace: String, tool: String,
                         status: String, success: Bool?)
    case webSearch(id: String, query: String, action: WebSearchAction?)
    case contextCompaction(id: String)
    case imageGeneration(id: String, status: String, revisedPrompt: String, savedPath: String)
    case imageView(id: String, path: String)
    case enteredReviewMode(id: String)
    case exitedReviewMode(id: String)
    case hookPrompt(id: String, fragments: String)
    case plan(id: String, text: String)
    // 子智能体项：聚合进 ConversationState.subAgents，不作可见卡片（见 ThreadReducer.absorb）。
    case collabAgentToolCall(id: String)
    case subAgentActivity(id: String)
    case unknown(id: String, type: String)                   // D4：未识别 type 兜底，保留 type 备查

    var id: String {
        switch self {
        case .userMessage(let i, _, _), .agentMessage(let i, _), .reasoning(let i, _),
             .commandExecution(let i, _, _, _, _, _, _), .fileChange(let i, _, _, _, _),
             .mcpToolCall(let i, _, _, _, _, _), .dynamicToolCall(let i, _, _, _, _),
             .webSearch(let i, _, _), .contextCompaction(let i),
             .imageGeneration(let i, _, _, _), .imageView(let i, _),
             .enteredReviewMode(let i), .exitedReviewMode(let i),
             .hookPrompt(let i, _), .plan(let i, _),
             .collabAgentToolCall(let i), .subAgentActivity(let i),
             .unknown(let i, _):
            return i
        }
    }
}

enum IncrementalTextLineCount {
    static func count(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return 1 + newlineCount(text)
    }

    static func appending(currentCount: Int, currentIsEmpty: Bool, delta: String) -> Int {
        guard !delta.isEmpty else { return currentCount }
        return currentIsEmpty ? count(delta) : currentCount + newlineCount(delta)
    }

    private static func newlineCount(_ text: String) -> Int {
        text.utf8.reduce(into: 0) { count, byte in
            if byte == 0x0A { count += 1 }
        }
    }
}

/// 单个会话（thread）的归约状态。
struct ConversationState: Equatable {
    var threadId: String
    var items: [ConversationItem] = []
    var activeTurnId: String?
    var activeTurnKind: NonSteerableTurnKind?    // 非 nil 表示当前 turn 不可 steer
    /// 当前 turn 的 plan 步骤（来自 turn/plan/updated，整体快照）。摘要「进度」P0 数据源。
    var plan: [TurnPlanStep] = []
    /// 当前 turn 的聚合 unified diff 全文（来自 turn/diff/updated）。
    /// +A−B、变更文件数、change3 逐行 diff 的唯一真相源。
    var turnDiff: String = ""
    /// 当前会话子智能体聚合状态（批次⑤，agentThreadId → 状态）。
    var subAgents: [String: SubAgentState] = [:]
    /// 进行中的 item id 集合（来源：item/started 加入、item/completed 移除）。
    /// D4：turn/started 不广播给非发起端，运行态改由逐-item 信号驱动，跨端一致真实。
    var inFlightItemIds: Set<String> = []
    /// 最近一次发送失败信息（D2）；nil = 无错误。UI 据此显式提示并停止"生成中"。
    var lastSendError: String?
    /// resume 遇到未来未知 turn status 时保留原值，便于诊断；行为一律 fail-closed 为非运行中。
    var unknownTurnStatuses: [String] = []
    /// 运行态（"生成中"）：有进行中 item 即为真；activeTurnId 作发起端兜底信号。
    var isTurnRunning: Bool { !inFlightItemIds.isEmpty || activeTurnId != nil }

    /// 本会话执行过的命令条数（纯派生，用于「已运行 N 条命令」汇总）。
    var commandCount: Int {
        items.reduce(0) { count, item in
            if case .commandExecution = item { return count + 1 }
            return count
        }
    }
}
