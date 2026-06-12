import Foundation

/// 把 server notification 归约进 ConversationState 的纯函数集合。
///
/// 两条摄入路径：
///   1. `apply(_:to:)` —— 流式 server notification（turn/item 增量），字段名
///      itemId/delta/itemType/command/kind/file/added/removed/diff 取自流式协议。
///   2. `ingest(resumeResult:to:)` —— thread/resume 同步响应里的历史 turn/item，
///      字段名取自 Task 20 实测真实 schema（见方法注释），与流式形状不同。
struct ThreadReducer {
    func apply(_ n: JSONRPCNotification, to state: inout ConversationState) {
        let p = (n.params?.value as? [String: Any]) ?? [:]
        switch n.method {
        case ServerNotificationMethod.turnStarted:
            state.activeTurnId = p["turnId"] as? String
            if let kind = p["kind"] as? String {
                state.activeTurnKind = NonSteerableTurnKind(rawValue: kind)
            } else {
                state.activeTurnKind = nil
            }

        case ServerNotificationMethod.turnCompleted:
            state.activeTurnId = nil
            state.activeTurnKind = nil

        case ServerNotificationMethod.itemStarted:
            guard let id = p["itemId"] as? String else { return }
            switch p["itemType"] as? String {
            case "agentMessage":
                upsert(.agentMessage(id: id, text: ""), &state)
            case "commandExecution":
                upsert(.commandExecution(id: id, command: p["command"] as? String ?? "",
                                         output: "", finished: false), &state)
            case "fileChange":
                upsert(.fileChange(id: id, file: p["file"] as? String ?? "",
                                   added: 0, removed: 0, diff: ""), &state)
            default:
                break
            }

        case ServerNotificationMethod.agentMessageDelta:
            guard let id = p["itemId"] as? String, let d = p["delta"] as? String else { return }
            mutateAgent(id: id, append: d, &state)

        case ServerNotificationMethod.commandOutputDelta:
            guard let id = p["itemId"] as? String, let d = p["delta"] as? String else { return }
            mutateCommand(id: id, append: d, &state)

        case ServerNotificationMethod.fileChangePatchUpdated, ServerNotificationMethod.turnDiffUpdated:
            if let id = p["itemId"] as? String { mutateFile(id: id, params: p, &state) }

        case ServerNotificationMethod.itemCompleted:
            if let id = p["itemId"] as? String { finishCommand(id: id, &state) }

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

    private func mutateCommand(id: String, append: String, _ s: inout ConversationState) {
        guard let i = s.items.firstIndex(where: { $0.id == id }),
              case .commandExecution(_, let c, let o, let f) = s.items[i] else { return }
        s.items[i] = .commandExecution(id: id, command: c, output: o + append, finished: f)
    }

    private func mutateFile(id: String, params: [String: Any], _ s: inout ConversationState) {
        guard let i = s.items.firstIndex(where: { $0.id == id }),
              case .fileChange(_, let f, _, _, _) = s.items[i] else { return }
        s.items[i] = .fileChange(id: id, file: f,
                                 added: intValue(params["added"]),
                                 removed: intValue(params["removed"]),
                                 diff: params["diff"] as? String ?? "")
    }

    private func finishCommand(id: String, _ s: inout ConversationState) {
        guard let i = s.items.firstIndex(where: { $0.id == id }),
              case .commandExecution(_, let c, let o, _) = s.items[i] else { return }
        s.items[i] = .commandExecution(id: id, command: c, output: o, finished: true)
    }

    /// AnyCodable 解码整数为 Int64；内存构造时为 Int。两者都兼容。
    private func intValue(_ any: Any?) -> Int {
        if let i = any as? Int { return i }
        if let i = any as? Int64 { return Int(i) }
        if let d = any as? Double { return Int(d) }
        return 0
    }
}
