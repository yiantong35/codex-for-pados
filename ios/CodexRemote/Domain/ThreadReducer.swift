import Foundation

/// 把 server notification 归约进 ConversationState 的纯函数集合。
/// 字段名（itemId/delta/itemType/command/kind/file/added/removed/diff）按 protocol v2 核对；
/// Task 20 录制真实帧后若有出入回此校正（设计 §13 留待 build 确认项）。
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
