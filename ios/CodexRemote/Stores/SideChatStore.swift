import Foundation
import Observation

/// 单个侧聊会话只保存 fork 元数据；可见 ConversationView 是唯一 ConversationStore owner。
struct SideChatSession: Identifiable {
    let id: String
    let forkedFromId: String?
    let index: Int
    var title: String
    var hasMessageSummary = false

    init(id: String, forkedFromId: String?, index: Int = 0, title: String,
         hasMessageSummary: Bool = false) {
        self.id = id
        self.forkedFromId = forkedFromId
        self.index = index
        self.title = title
        self.hasMessageSummary = hasMessageSummary
    }
}

enum SideChatCloseResult: Equatable {
    case closed
    case requiresInterrupt
    case interruptFailed
}

/// 多侧聊生命周期状态层（design D2）：容器持有一份，视图只读渲染。
/// attach(rpc:) 注入共享 JSONRPCClient（幂等，模式同 FileBrowserStore）。
/// 每个侧聊只保留 ephemeral fork 元数据，通知订阅由当前可见 ConversationView 独占。
@Observable
@MainActor
final class SideChatStore {
    typealias ThreadStatusProvider = @MainActor (String) -> ThreadStatus?

    private(set) var sessions: [SideChatSession] = []
    var selectedId: String? {
        didSet {
            guard oldValue != selectedId, visibleStoreThreadId != selectedId else { return }
            releaseVisibleStore()
        }
    }
    private(set) var isStarting = false
    private(set) var startFailed = false

    private var rpc: JSONRPCClient?
    let conversationOutboxes: ConversationOutboxRegistry
    @ObservationIgnored private let draftStore: ComposerDraftStore?
    @ObservationIgnored private let threadStatus: ThreadStatusProvider
    private var rpcIdentity: ObjectIdentifier?
    private var visibleStore: ConversationStore?
    private var visibleStoreThreadId: String?
    /// 已开侧聊计数（只增），用于标题 #序号，与 close 无关（关掉不回收序号，避免标题跳变）。
    private var startedCount = 0

    init(draftStore: ComposerDraftStore? = nil,
         conversationOutboxes: ConversationOutboxRegistry = ConversationOutboxRegistry(),
         threadStatus: @escaping ThreadStatusProvider = { _ in nil }) {
        self.draftStore = draftStore
        self.conversationOutboxes = conversationOutboxes
        self.threadStatus = threadStatus
    }

    /// 注入共享 rpc（幂等）。重连时保留 metadata；可见 ConversationView 会按新 rpc identity 重建。
    func attach(rpc: JSONRPCClient) {
        let identity = ObjectIdentifier(rpc)
        if let rpcIdentity, rpcIdentity != identity {
            releaseVisibleStore()
        }
        rpcIdentity = identity
        self.rpc = rpc
    }

    func conversationStore(for threadId: String) -> ConversationStore? {
        if visibleStoreThreadId == threadId, let visibleStore { return visibleStore }
        guard let rpc else { return nil }
        releaseVisibleStore()
        let created = ConversationStore(
            rpc: rpc,
            threadId: threadId,
            outbox: conversationOutboxes.outbox(for: threadId)
        )
        created.onUserMessageEnqueued = { [weak self] text in
            self?.setFirstMessageSummary(text, for: threadId)
        }
        visibleStore = created
        visibleStoreThreadId = threadId
        return created
    }

    func isRunning(id: String) -> Bool {
        if visibleStoreThreadId == id, visibleStore?.state.isTurnRunning == true { return true }
        if case .active = threadStatus(id) { return true }
        return false
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
        let title = Self.makeTitle(index: startedCount)
        let session = SideChatSession(
            id: result.threadId,
            forkedFromId: result.forkedFromId,
            index: startedCount,
            title: title
        )
        sessions.append(session)
        selectedId = session.id
    }

    @discardableResult
    func reset() -> Task<Void, Never> {
        let activeThreadIds = sessions.map(\.id).filter { isRunning(id: $0) }
        let rpc = self.rpc
        sessions.forEach {
            draftStore?.removeDraft(for: $0.id)
            conversationOutboxes.remove(threadId: $0.id)
        }
        visibleStore?.stopObserving()
        visibleStore = nil
        visibleStoreThreadId = nil
        sessions.removeAll()
        selectedId = nil
        startFailed = false
        return Task {
            guard let rpc else { return }
            for threadId in activeThreadIds {
                _ = await Self.interrupt(threadId: threadId, rpc: rpc)
            }
        }
    }

    /// 关闭侧聊：移除 metadata；可见 ConversationView 随选择变化销毁并取消自己的订阅。
    @discardableResult
    func close(id: String, interruptIfRunning: Bool = false) async -> SideChatCloseResult {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return .closed }
        if isRunning(id: id) {
            guard interruptIfRunning else { return .requiresInterrupt }
            guard let rpc, await Self.interrupt(threadId: id, rpc: rpc) else {
                return .interruptFailed
            }
        }
        if visibleStoreThreadId == id, let conversation = visibleStore {
            conversation.stopObserving()
            visibleStore = nil
            visibleStoreThreadId = nil
        }
        sessions.remove(at: idx)
        conversationOutboxes.remove(threadId: id)
        draftStore?.removeDraft(for: id)
        if selectedId == id {
            selectedId = sessions.isEmpty ? nil : sessions[min(idx, sessions.count - 1)].id
        }
        return .closed
    }

    private func releaseVisibleStore() {
        visibleStore?.stopObserving()
        visibleStore = nil
        visibleStoreThreadId = nil
    }

    private static func interrupt(threadId: String, rpc: JSONRPCClient) async -> Bool {
        guard let data = try? JSONEncoder().encode(TurnInterruptParams(threadId: threadId)),
              let params = try? JSONDecoder().decode(AnyCodable.self, from: data) else { return false }
        do {
            _ = try await rpc.send(method: RPCMethod.turnInterrupt, params: params)
            return true
        } catch {
            return false
        }
    }

    func rename(id: String, title: String) {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].title = value
        sessions[index].hasMessageSummary = true
    }

    static func makeTitle(index: Int) -> String {
        String.localizedStringWithFormat(
            L10n.string("sideChat.defaultTitle %lld", locale: LocaleManager.currentLocale), index
        )
    }

    private func setFirstMessageSummary(_ text: String, for id: String) {
        guard let index = sessions.firstIndex(where: { $0.id == id }),
              !sessions[index].hasMessageSummary else { return }
        let summary = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        guard !summary.isEmpty else { return }
        sessions[index].title += " · " + String(summary.prefix(36))
        sessions[index].hasMessageSummary = true
    }
}
