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
            state.inFlightItemIds.removeAll()   // D4：兜底清空进行中 item 计数

        case ServerNotificationMethod.itemStarted:
            // 真实通知：item 是嵌套对象，字段在 params.item.{id,type,command,file}
            // （旧实现读扁平 params.itemId/itemType/command → 命令卡片永不出现，是滞后 bug 根因 B）。
            guard let item = p["item"] as? [String: Any],
                  let id = item["id"] as? String else { return }
            // D4：item 进行中 → 运行态为真。userMessage 是即时项（无对应 completed），
            // 计入会使运行态永久卡住，故排除。
            if item["type"] as? String != "userMessage" {
                state.inFlightItemIds.insert(id)
            }
            applySubAgentItem(item, &state)   // 批次⑤：子智能体聚合
            switch item["type"] as? String {
            case "userMessage":
                // D3：流式 userMessage（本端或他端回显）。与乐观项对账，避免重复气泡。
                reconcileUserMessage(id: id, text: textFromContent(item["content"]), &state)
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
                // 非流式静态类型（mcpToolCall/webSearch/未来类型…）统一走 parseItem，
                // 与 history 一致；collab/subAgent 已在上方 applySubAgentItem 聚合，absorb 会跳过。
                if let ci = parseItem(item) { absorb(ci, replace: true, &state) }
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
            state.inFlightItemIds.remove(id)   // D4：item 完成 → 移出进行中集合
            applySubAgentItem(item, &state)   // 批次⑤：子智能体状态迁移
            switch item["type"] as? String {
            case "reasoning":
                // 收尾：完成事件带最终文本且本地为空时补落（不覆盖已累加 delta）。
                finishReasoning(id: id, fallbackText: reasoningText(from: item), &state)
            case "commandExecution":
                let status = CommandStatus(rawValue: item["status"] as? String ?? "") ?? .completed
                finishCommand(id: id, status: status,
                              exitCode: optionalInt(item["exitCode"]),
                              durationMs: optionalInt(item["durationMs"]),
                              fallbackOutput: item["aggregatedOutput"] as? String ?? "", &state)
            case "userMessage", "agentMessage", "fileChange":
                break   // started 已建项；完成态无额外最终字段（fileChange 走 patchUpdated）。
            default:
                // 静态类型：完成态字段最全，整体替换落地。
                if let ci = parseItem(item) { absorb(ci, replace: true, &state) }
            }

        default:
            break
        }
    }

    // MARK: - 统一解析入口（D2：live 与 history 共用最终态解析）

    /// 一个完整 item dict → ConversationItem。
    /// 已识别 type 一律返回具体 case；未识别 type → .unknown（D4，绝不静默丢弃）；仅 id 缺失返回 nil。
    /// 每种解析对缺失字段给默认值，单字段缺失不丢整条。
    func parseItem(_ item: [String: Any]) -> ConversationItem? {
        guard let id = item["id"] as? String else { return nil }
        switch item["type"] as? String {
        case "userMessage":
            return .userMessage(id: id, text: textFromContent(item["content"]))
        case "agentMessage":
            return .agentMessage(id: id, text: item["text"] as? String ?? "")
        case "reasoning":
            return .reasoning(id: id, text: reasoningText(from: item))
        case "commandExecution":
            let status = CommandStatus(rawValue: item["status"] as? String ?? "") ?? .inProgress
            return .commandExecution(id: id,
                                     command: item["command"] as? String ?? "",
                                     output: item["aggregatedOutput"] as? String ?? "",
                                     status: status,
                                     exitCode: optionalInt(item["exitCode"]),
                                     durationMs: optionalInt(item["durationMs"]))
        case "fileChange":
            let changes = item["changes"] as? [[String: Any]] ?? []
            let combined = changes.compactMap { $0["diff"] as? String }.joined(separator: "\n")
            let stat = TurnDiffStats.parse(combined)
            return .fileChange(id: id,
                               file: changes.first?["path"] as? String ?? "",
                               added: stat.added, removed: stat.removed, diff: combined)
        case "mcpToolCall":
            return .mcpToolCall(id: id,
                                server: item["server"] as? String ?? "",
                                tool: item["tool"] as? String ?? "",
                                status: item["status"] as? String ?? "",
                                result: mcpResultSummary(item["result"]),
                                durationMs: optionalInt(item["durationMs"]))
        case "dynamicToolCall":
            return .dynamicToolCall(id: id,
                                    namespace: item["namespace"] as? String ?? "",
                                    tool: item["tool"] as? String ?? "",
                                    status: item["status"] as? String ?? "",
                                    success: item["success"] as? Bool)
        case "webSearch":
            return .webSearch(id: id,
                              query: item["query"] as? String ?? "",
                              action: item["action"] as? String ?? "")
        case "contextCompaction":
            return .contextCompaction(id: id)
        case "imageGeneration":
            return .imageGeneration(id: id,
                                    status: item["status"] as? String ?? "",
                                    revisedPrompt: item["revisedPrompt"] as? String ?? "",
                                    savedPath: item["savedPath"] as? String ?? "")
        case "imageView":
            return .imageView(id: id, path: item["path"] as? String ?? "")
        case "enteredReviewMode":
            return .enteredReviewMode(id: id)
        case "exitedReviewMode":
            return .exitedReviewMode(id: id)
        case "hookPrompt":
            return .hookPrompt(id: id, fragments: textFromContent(item["fragments"]))
        case "plan":
            return .plan(id: id, text: planText(from: item))
        case "collabAgentToolCall":
            return .collabAgentToolCall(id: id)
        case "subAgentActivity":
            return .subAgentActivity(id: id)
        case let other?:
            return .unknown(id: id, type: other)
        case nil:
            return .unknown(id: id, type: "")
        }
    }

    /// mcpToolCall.result 摘要：字符串直用；结构体尝试取 content 文本；否则空串。
    private func mcpResultSummary(_ any: Any?) -> String {
        if let s = any as? String { return s }
        if let d = any as? [String: Any] { return textFromContent(d["content"]) }
        return ""
    }

    /// plan item 文本：优先 text 字段，否则拼接步骤 step。
    private func planText(from item: [String: Any]) -> String {
        if let t = item["text"] as? String { return t }
        let steps = (item["plan"] as? [[String: Any]]) ?? (item["steps"] as? [[String: Any]]) ?? []
        return steps.compactMap { $0["step"] as? String }.joined(separator: "\n")
    }

    /// 把 parseItem 结果并入可见 items。
    /// collab/subAgent 已由 applySubAgentItem 聚合进 state.subAgents，不作可见卡片（与 live 一致）。
    private func absorb(_ ci: ConversationItem, replace: Bool, _ s: inout ConversationState) {
        switch ci {
        case .collabAgentToolCall, .subAgentActivity:
            return
        default:
            if replace { upsertOrReplace(ci, &s) } else { upsert(ci, &s) }
        }
    }

    /// 按 id 存在则整体替换（落最终态字段），否则追加。用于非流式静态类型。
    private func upsertOrReplace(_ item: ConversationItem, _ s: inout ConversationState) {
        if let i = s.items.firstIndex(where: { $0.id == item.id }) {
            s.items[i] = item
        } else {
            s.items.append(item)
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
        guard item["id"] is String else { return }
        applySubAgentItem(item, &s)          // 子智能体聚合，与 live 一致（Task 5.2）
        guard let ci = parseItem(item) else { return }
        absorb(ci, replace: false, &s)       // history 单次摄入，first-write-wins
    }

    /// 从 content 拼纯文本。兼容两种形态：
    ///   - v2:   ["文本1", "文本2"]（Array<string>）
    ///   - 遗留: [{"type":"...","text":"..."}]
    private func textFromContent(_ content: Any?) -> String {
        if let strs = content as? [String] { return strs.joined(separator: "\n") }
        if let parts = content as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }.joined()
        }
        return ""
    }

    // MARK: - mutators

    private func upsert(_ item: ConversationItem, _ s: inout ConversationState) {
        if !s.items.contains(where: { $0.id == item.id }) { s.items.append(item) }
    }

    /// D3 乐观回显：插入本地临时 userMessage（供 ConversationStore.send 调用）。
    func upsertUserMessage(id: String, text: String, to s: inout ConversationState) {
        upsert(.userMessage(id: id, text: text), &s)
    }

    /// D3 对账：权威 userMessage 到达时，若存在内容相同的乐观项（local- 前缀）则替换其 id 为
    /// 权威 id；否则按权威 id 插入（他端发起场景）。避免重复气泡。
    private func reconcileUserMessage(id: String, text: String, _ s: inout ConversationState) {
        if let idx = s.items.firstIndex(where: {
            if case .userMessage(let i, let t) = $0 { return i.hasPrefix("local-") && t == text }
            return false
        }) {
            s.items[idx] = .userMessage(id: id, text: text)   // 替换乐观项为权威项
        } else if !s.items.contains(where: { $0.id == id }) {
            s.items.append(.userMessage(id: id, text: text))  // 他端发起：正常插入
        }
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
                               exitCode: Int?, durationMs: Int?,
                               fallbackOutput: String = "", _ s: inout ConversationState) {
        guard let i = s.items.firstIndex(where: { $0.id == id }),
              case .commandExecution(_, let c, let o, _, _, _) = s.items[i] else { return }
        // completed/failed/declined 都视为命令已结束，落终态字段。
        // output 优先保留 delta 累加值；若 delta 未到（如纯 aggregatedOutput 完成事件），用兜底补落。
        let output = o.isEmpty ? fallbackOutput : o
        s.items[i] = .commandExecution(id: id, command: c, output: output,
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
