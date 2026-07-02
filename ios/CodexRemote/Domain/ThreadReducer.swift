import Foundation

/// 把 server notification 归约进 ConversationState 的纯函数集合。
///
/// 两条摄入路径：
///   1. `apply(_:to:)` —— 流式 server notification（turn/item 增量）。
///      真实通知（codex 0.133.0 实测，见 realTurnSequence.json）形状：
///        - turn/started·completed: turn 嵌套在 params.turn（id=params.turn.id, status=params.turn.status，无 kind）
///        - item/started·completed:  item 嵌套在 params.item（id/type/command/status/exitCode/aggregatedOutput…）
///        - item/agentMessage/delta、item/commandExecution/outputDelta: 字段**扁平** params.itemId/params.delta
///        - turn/diff/updated、fileChange/patchUpdated: 扁平 params.itemId/added/removed/diff
///   2. `ingest(resumeResult:to:)` —— thread/resume 同步响应里的历史 turn/item，
///      字段名取自 Task 20 实测真实 schema（见方法注释），与流式形状不同。
struct ThreadReducer {
    func apply(_ n: JSONRPCNotification, to state: inout ConversationState) {
        let p = (n.params?.value as? [String: Any]) ?? [:]
        switch n.method {
        case ServerNotificationMethod.turnStarted:
            // 真实通知（codex 0.133.0 实测）：turn 是嵌套对象，id 在 params.turn.id，
            // 无 kind 字段（旧实现读扁平 params.turnId/params.kind → 永远 nil，是滞后 bug 根因 B）。
            let turn = p["turn"] as? [String: Any]
            state.activeTurnId = turn?["id"] as? String
            if let kind = (turn?["kind"] ?? p["kind"]) as? String {
                state.activeTurnKind = NonSteerableTurnKind(rawValue: kind)
            } else {
                state.activeTurnKind = nil
            }

        case ServerNotificationMethod.turnCompleted:
            state.activeTurnId = nil
            state.activeTurnKind = nil

        case ServerNotificationMethod.itemStarted:
            // 真实通知：item 是嵌套对象，字段在 params.item.{id,type,command,file}
            // （旧实现读扁平 params.itemId/itemType/command → 命令卡片永不出现，是滞后 bug 根因 B）。
            guard let item = p["item"] as? [String: Any],
                  let id = item["id"] as? String else { return }
            applySubAgentItem(item, &state)   // 批次⑤：子智能体聚合
            switch item["type"] as? String {
            case "agentMessage":
                upsert(.agentMessage(id: id, text: item["text"] as? String ?? ""), &state)
            case "commandExecution":
                upsert(.commandExecution(id: id, command: item["command"] as? String ?? "",
                                         output: "", status: .inProgress,
                                         exitCode: nil, durationMs: nil), &state)
            case "fileChange":
                upsert(.fileChange(id: id, file: item["file"] as? String ?? "",
                                   added: 0, removed: 0, diff: ""), &state)
            case "reasoning":
                // 思考/推理项：item.summary/content 可能已带文本（[{type, text}]），否则空串占位（UI 显「正在思考…」）。
                upsert(.reasoning(id: id, text: reasoningText(from: item)), &state)
            default:
                break
            }

        case ServerNotificationMethod.agentMessageDelta:
            guard let id = p["itemId"] as? String, let d = p["delta"] as? String else { return }
            mutateAgent(id: id, append: d, &state)

        case ServerNotificationMethod.reasoningTextDelta, ServerNotificationMethod.reasoningSummaryTextDelta:
            // 正文与摘要增量都累加进同一 reasoning item（字段扁平 itemId/delta）。
            guard let id = p["itemId"] as? String, let d = p["delta"] as? String else { return }
            mutateReasoning(id: id, append: d, &state)

        case ServerNotificationMethod.commandOutputDelta:
            guard let id = p["itemId"] as? String, let d = p["delta"] as? String else { return }
            mutateCommand(id: id, append: d, &state)

        case ServerNotificationMethod.turnDiffUpdated:
            // 真实协议：{threadId, turnId, diff} —— 无 itemId。整 turn 聚合 diff 全文，直接存。
            // （旧实现走 itemId guard → 整 turn diff 被丢弃，是 diff 行数恒 0 的 bug 根因之一。）
            if let d = p["diff"] as? String { state.turnDiff = d }

        case ServerNotificationMethod.fileChangePatchUpdated:
            // 真实协议：{threadId, turnId, itemId, changes:[{path, kind, diff}]}。
            // 遍历 changes，按 path 把每文件 diff 文本与解析行数落入对应 fileChange item。
            applyFilePatch(itemId: p["itemId"] as? String, params: p, &state)

        case ServerNotificationMethod.turnPlanUpdated:
            // plan 是整体快照：每次用最新数组替换（缺字段容错，step 缺省空串、status 缺省 pending）。
            let raw = p["plan"] as? [[String: Any]] ?? []
            state.plan = raw.map { entry in
                TurnPlanStep(step: entry["step"] as? String ?? "",
                             status: TurnPlanStepStatus.from(any: entry["status"]))
            }

        case ServerNotificationMethod.itemCompleted:
            // 真实通知：item 嵌套在 params.item，命令完成状态在 item.status
            // （CommandExecutionStatus: inProgress|completed|failed|declined），
            // 退出码 item.exitCode、耗时 item.durationMs。
            guard let item = p["item"] as? [String: Any],
                  let id = item["id"] as? String else { return }
            applySubAgentItem(item, &state)   // 批次⑤：子智能体状态迁移
            // reasoning 收尾：若完成事件带了最终 summary/content，且本地为空则补落（不覆盖已累加的 delta）。
            if item["type"] as? String == "reasoning" {
                finishReasoning(id: id, fallbackText: reasoningText(from: item), &state)
                return
            }
            let status = CommandStatus(rawValue: item["status"] as? String ?? "") ?? .completed
            finishCommand(id: id, status: status,
                          exitCode: optionalInt(item["exitCode"]),
                          durationMs: optionalInt(item["durationMs"]), &state)

        default:
            break
        }
    }

    // MARK: - resume 历史摄入

    /// 把 `thread/resume` 同步响应里的历史 turn/item 摄入 state。
    ///
    /// 真实响应（Task 20 实测）形状：
    /// ```
    /// { thread: { turns: [ { items: [ <item> ] } ] }, model, ... }
    /// ```
    /// item 按 `type` 区分，字段名与流式协议不同：
    ///   - userMessage:  { type, id, content:[{type:"text", text, ...}] } → 拼接所有 text 片段
    ///   - agentMessage: { type, id, text }                              → text 为顶层直接字段
    ///   - fileChange:   { type, id, changes:[{path, kind:{type}, diff}] } → 取首个 change 渲染
    /// 其它 type（mcpToolCall/webSearch/contextCompaction 等）当前无对应渲染项，跳过。
    /// 幂等：已存在的 id 不重复追加（复用 upsert 语义）。
    func ingest(resumeResult result: [String: Any], to state: inout ConversationState) {
        let thread = result["thread"] as? [String: Any]
        let turns = (thread?["turns"] as? [[String: Any]])
            ?? (result["turns"] as? [[String: Any]]) ?? []
        for turn in turns {
            let items = turn["items"] as? [[String: Any]] ?? []
            for item in items { ingestHistoryItem(item, &state) }
        }
    }

    private func ingestHistoryItem(_ item: [String: Any], _ s: inout ConversationState) {
        guard let id = item["id"] as? String else { return }
        switch item["type"] as? String {
        case "userMessage":
            upsert(.userMessage(id: id, text: textFromContent(item["content"])), &s)
        case "agentMessage":
            upsert(.agentMessage(id: id, text: item["text"] as? String ?? ""), &s)
        case "reasoning":
            upsert(.reasoning(id: id, text: reasoningText(from: item)), &s)
        case "fileChange":
            let changes = item["changes"] as? [[String: Any]] ?? []
            let first = changes.first
            upsert(.fileChange(id: id,
                               file: first?["path"] as? String ?? "",
                               added: 0, removed: 0,
                               diff: first?["diff"] as? String ?? ""), &s)
        default:
            break   // 暂不渲染的历史 item 类型
        }
    }

    /// 从 userMessage.content（[{type:"text", text}]）拼接出纯文本。
    private func textFromContent(_ content: Any?) -> String {
        guard let parts = content as? [[String: Any]] else { return "" }
        return parts.compactMap { $0["text"] as? String }.joined()
    }

    // MARK: - mutators

    private func upsert(_ item: ConversationItem, _ s: inout ConversationState) {
        if !s.items.contains(where: { $0.id == item.id }) { s.items.append(item) }
    }

    private func mutateAgent(id: String, append: String, _ s: inout ConversationState) {
        guard let i = s.items.firstIndex(where: { $0.id == id }) else {
            // delta 先于 item/started 到达：建一个空 agentMessage 再累加
            s.items.append(.agentMessage(id: id, text: append))
            return
        }
        guard case .agentMessage(_, let t) = s.items[i] else { return }
        s.items[i] = .agentMessage(id: id, text: t + append)
    }

    private func mutateReasoning(id: String, append: String, _ s: inout ConversationState) {
        guard let i = s.items.firstIndex(where: { $0.id == id }) else {
            // delta 先于 item/started 到达：建一个空 reasoning 再累加（与 agentMessage 容错一致）。
            s.items.append(.reasoning(id: id, text: append))
            return
        }
        guard case .reasoning(_, let t) = s.items[i] else { return }
        s.items[i] = .reasoning(id: id, text: t + append)
    }

    /// reasoning 完成收尾：本地累加为空但完成事件带了文本时补落，已有内容则保留。
    private func finishReasoning(id: String, fallbackText: String, _ s: inout ConversationState) {
        guard let i = s.items.firstIndex(where: { $0.id == id }) else {
            upsert(.reasoning(id: id, text: fallbackText), &s)
            return
        }
        guard case .reasoning(_, let t) = s.items[i] else { return }
        if t.isEmpty && !fallbackText.isEmpty {
            s.items[i] = .reasoning(id: id, text: fallbackText)
        }
    }

    /// 从 reasoning item 的 summary/content（[{type, text}]）拼接出纯文本，无则空串。
    private func reasoningText(from item: [String: Any]) -> String {
        let summary = textFromContent(item["summary"])
        let content = textFromContent(item["content"])
        return [summary, content].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private func mutateCommand(id: String, append: String, _ s: inout ConversationState) {
        guard let i = s.items.firstIndex(where: { $0.id == id }),
              case .commandExecution(_, let c, let o, let st, let ec, let dm) = s.items[i] else { return }
        s.items[i] = .commandExecution(id: id, command: c, output: o + append,
                                       status: st, exitCode: ec, durationMs: dm)
    }

    /// 批次⑤：从 item 聚合子智能体状态到 ConversationState.subAgents。幂等，非相关 type 无操作。
    private func applySubAgentItem(_ item: [String: Any], _ s: inout ConversationState) {
        switch item["type"] as? String {
        case "collabAgentToolCall":
            guard let states = item["agentsStates"] as? [String: Any] else { return }
            for (tid, raw) in states {
                let st = raw as? [String: Any]
                let status = CollabAgentStatus.from(st?["status"] as? String)
                let msg = st?["message"] as? String
                if var existing = s.subAgents[tid] {
                    existing.status = status; existing.message = msg; s.subAgents[tid] = existing
                } else {
                    s.subAgents[tid] = SubAgentState(agentThreadId: tid, path: nil, status: status, message: msg)
                }
            }
        case "subAgentActivity":
            guard let tid = item["agentThreadId"] as? String else { return }
            let path = item["agentPath"] as? String
            if var existing = s.subAgents[tid] {
                if let path { existing.path = path }; s.subAgents[tid] = existing
            } else {
                s.subAgents[tid] = SubAgentState(agentThreadId: tid, path: path, status: .running, message: nil)
            }
        default:
            break
        }
    }

    /// 处理 fileChange/patchUpdated：遍历 changes[]，对每个 {path, diff} 用 TurnDiffStats 解析行数，
    /// 落入对应 fileChange item（按 itemId 优先匹配；多文件时按 path 匹配既有 item，缺失则忽略）。
    private func applyFilePatch(itemId: String?, params: [String: Any], _ s: inout ConversationState) {
        let changes = params["changes"] as? [[String: Any]] ?? []
        for change in changes {
            let path = change["path"] as? String ?? ""
            let diff = change["diff"] as? String ?? ""
            let stat = TurnDiffStats.parse(diff)
            // 优先按 itemId 命中（单文件常见），否则按 file path 命中既有 item
            let idx = s.items.firstIndex {
                if case .fileChange(let id, let f, _, _, _) = $0 {
                    return (itemId != nil && id == itemId) || f == path
                }
                return false
            }
            guard let i = idx, case .fileChange(let id, _, _, _, _) = s.items[i] else { continue }
            s.items[i] = .fileChange(id: id, file: path,
                                     added: stat.added, removed: stat.removed, diff: diff)
        }
    }

    private func finishCommand(id: String, status: CommandStatus,
                               exitCode: Int?, durationMs: Int?, _ s: inout ConversationState) {
        guard let i = s.items.firstIndex(where: { $0.id == id }),
              case .commandExecution(_, let c, let o, _, _, _) = s.items[i] else { return }
        // completed/failed/declined 都视为命令已结束，落终态字段。
        s.items[i] = .commandExecution(id: id, command: c, output: o,
                                       status: status, exitCode: exitCode, durationMs: durationMs)
    }

    /// AnyCodable 解码整数为 Int64；内存构造时为 Int。两者都兼容。
    private func intValue(_ any: Any?) -> Int {
        if let i = any as? Int { return i }
        if let i = any as? Int64 { return Int(i) }
        if let d = any as? Double { return Int(d) }
        return 0
    }

    /// 可空整数解码：字段缺失/为 null 时返回 nil（用于 exitCode/durationMs）。
    private func optionalInt(_ any: Any?) -> Int? {
        if any == nil { return nil }
        if let i = any as? Int { return i }
        if let i = any as? Int64 { return Int(i) }
        if let d = any as? Double { return Int(d) }
        return nil
    }
}
