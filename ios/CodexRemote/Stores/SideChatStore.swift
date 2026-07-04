import Foundation
import Observation

/// 单个侧聊会话：ephemeral fork 出的独立线程 + 内嵌 ConversationStore（复用流式/输入/审批）+ 展示标题。
struct SideChatSession: Identifiable {
    let id: String                       // 稳定标识（= fork 出的 threadId）
    let conversation: ConversationStore  // 内嵌会话状态层（已订阅本线程）
    let title: String                    // 展示标题：forkedFromId 前8位·#序号
}

/// 多侧聊生命周期状态层（design D2）：容器持有一份，视图只读渲染。
/// attach(rpc:) 注入共享 JSONRPCClient（幂等，模式同 FileBrowserStore）。
/// 每个侧聊 = 一个 ephemeral fork 出的线程 + 一个 ConversationStore（订阅同一广播、按 threadId 过滤）。
@Observable
@MainActor
final class SideChatStore {
    private(set) var sessions: [SideChatSession] = []
    var selectedId: String?

    private var rpc: JSONRPCClient?
    /// 已开侧聊计数（只增），用于标题 #序号，与 close 无关（关掉不回收序号，避免标题跳变）。
    private var startedCount = 0

    /// 注入共享 rpc（幂等）。无初始请求——由 start 触发。
    func attach(rpc: JSONRPCClient) { self.rpc = rpc }

    /// 从主对话 fork 一个 ephemeral 侧聊。无 rpc / 无主对话 threadId → 直接返回，不发请求。
    func start(fromThreadId mainThreadId: String?) async {
        guard let rpc, let mainThreadId, !mainThreadId.isEmpty else { return }
        let forker = ConversationStore(rpc: rpc, threadId: mainThreadId)
        guard let result = await forker.fork(ephemeral: true) else { return }

        let convo = ConversationStore(rpc: rpc, threadId: result.threadId)
        await convo.startObserving()   // 先订阅再返回，避免漏掉随后到达的事件

        startedCount += 1
        let title = Self.makeTitle(forkedFromId: result.forkedFromId, index: startedCount)
        let session = SideChatSession(id: result.threadId, conversation: convo, title: title)
        sessions.append(session)
        selectedId = session.id
    }

    /// 关闭侧聊：停其订阅、从集合移除；若关的是选中项，选中态回退到其余任一（或 nil）。
    func close(id: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].conversation.stopObserving()
        sessions.remove(at: idx)
        if selectedId == id {
            selectedId = sessions.first?.id
        }
    }

    /// 标题：forkedFromId 前 8 位（缺则用 "side"）· #序号。
    static func makeTitle(forkedFromId: String?, index: Int) -> String {
        let prefix = forkedFromId.map { String($0.prefix(8)) } ?? "side"
        return "\(prefix)·#\(index)"
    }
}
