import Foundation
import Observation

/// 单个侧聊会话只保存 fork 元数据；可见 ConversationView 是唯一 ConversationStore owner。
struct SideChatSession: Identifiable {
    let id: String
    let forkedFromId: String?
    let title: String
}

/// 多侧聊生命周期状态层（design D2）：容器持有一份，视图只读渲染。
/// attach(rpc:) 注入共享 JSONRPCClient（幂等，模式同 FileBrowserStore）。
/// 每个侧聊只保留 ephemeral fork 元数据，通知订阅由当前可见 ConversationView 独占。
@Observable
@MainActor
final class SideChatStore {
    private(set) var sessions: [SideChatSession] = []
    var selectedId: String?
    private(set) var isStarting = false
    private(set) var startFailed = false

    private var rpc: JSONRPCClient?
    let conversationOutboxes = ConversationOutboxRegistry()
    /// 已开侧聊计数（只增），用于标题 #序号，与 close 无关（关掉不回收序号，避免标题跳变）。
    private var startedCount = 0

    /// 注入共享 rpc（幂等）。重连时保留 metadata；可见 ConversationView 会按新 rpc identity 重建。
    func attach(rpc: JSONRPCClient) {
        self.rpc = rpc
    }

    /// 从主对话 fork 一个 ephemeral 侧聊。无 rpc / 无主对话 threadId → 直接返回，不发请求。
    func start(fromThreadId mainThreadId: String?) async {
        guard !isStarting else { return }
        startFailed = false
        guard let rpc, let mainThreadId, !mainThreadId.isEmpty else {
            startFailed = true
            return
        }
        isStarting = true
        defer { isStarting = false }
        let forker = ConversationStore(rpc: rpc, threadId: mainThreadId)
        guard let result = await forker.fork(ephemeral: true) else {
            startFailed = true
            return
        }

        startedCount += 1
        let title = Self.makeTitle(forkedFromId: result.forkedFromId, index: startedCount)
        let session = SideChatSession(id: result.threadId, forkedFromId: result.forkedFromId, title: title)
        sessions.append(session)
        selectedId = session.id
    }

    func reset() {
        sessions.removeAll()
        selectedId = nil
        startFailed = false
    }

    /// 关闭侧聊：移除 metadata；可见 ConversationView 随选择变化销毁并取消自己的订阅。
    func close(id: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions.remove(at: idx)
        conversationOutboxes.remove(threadId: id)
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
