import SwiftUI

/// 侧聊面板（design D3/D4）：顶部侧聊选择器（多侧聊切换条 + 「开始侧聊」+ 每条关闭）+
/// 选中侧聊的完整 ConversationView（复用中栏视图：消息流 + 输入 + 审批卡，窄栏不特殊处理）。
/// 无主对话（mainThreadId 空）→ 空态提示、「开始侧聊」禁用、不 fork。
struct SideChatView: View {
    @Environment(ConnectionStore.self) private var connection
    @Environment(SessionsManager.self) private var sessions
    @Environment(ApprovalStore.self) private var approvals
    @Environment(UserInputStore.self) private var userInputs
    @Environment(McpElicitationStore.self) private var mcpElicitations
    @Bindable var store: SideChatStore
    @State private var pendingCloseID: String?
    /// 当前主对话 threadId：侧聊从它 fork。nil/空 → 无主对话空态。
    var mainThreadId: String?

    private var hasMainThread: Bool {
        !(mainThreadId ?? "").isEmpty
    }

    static func contentIdentity(for session: SideChatSession) -> String { session.id }

    var body: some View {
        VStack(spacing: 0) {
            selectorBar
            if store.startFailed {
                Label("operation.failed.description", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            content
        }
        .confirmationDialog(
            "sideChat.closeRunning.title",
            isPresented: Binding(
                get: { pendingCloseID != nil },
                set: { if !$0 { pendingCloseID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("sideChat.closeRunning.confirm", role: .destructive) {
                guard let id = pendingCloseID else { return }
                pendingCloseID = nil
                Task { await closeSession(id: id, interrupt: true) }
            }
            Button("common.cancel", role: .cancel) { pendingCloseID = nil }
        } message: {
            Text("sideChat.closeRunning.message")
        }
    }

    private var selectorBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button {
                    Task { await store.start(fromThreadId: mainThreadId) }
                } label: {
                    Label("sideChat.start", systemImage: "plus.bubble")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .minimumHitTarget44()
                .disabled(!hasMainThread || connection.phase != .ready || store.isStarting)

                ForEach(store.sessions) { session in
                    sessionChip(session)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }

    private func sessionChip(_ session: SideChatSession) -> some View {
        HStack(spacing: 4) {
            Button { store.selectedId = session.id } label: {
                Text(session.title)
                    .font(.caption)
                    .fontWeight(store.selectedId == session.id ? .semibold : .regular)
            }
            .buttonStyle(.plain)
            .minimumHitTarget44()
            .accessibilityAddTraits(store.selectedId == session.id ? [.isSelected] : [])
            Button { requestClose(id: session.id) } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .minimumHitTarget44()
            .accessibilityLabel("sideChat.close")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(store.selectedId == session.id ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1))
        .clipShape(Capsule())
    }

    @ViewBuilder
    private var content: some View {
        if !hasMainThread {
            emptyState("sideChat.noMainThread")
        } else if let id = store.selectedId,
                  let session = store.sessions.first(where: { $0.id == id }),
                  let conversation = store.conversationStore(for: session.id) {
            ConversationView(
                threadId: session.id,
                bindsWorkspaceState: false,
                providedStore: conversation,
                draftStore: sessions.activeSession?.composerDrafts
            )
            .id(Self.contentIdentity(for: session))
        } else {
            emptyState("sideChat.pickToStart")
        }
    }

    private func emptyState(_ key: LocalizedStringKey) -> some View {
        VStack {
            Spacer()
            Text(key)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func requestClose(id: String) {
        if store.isRunning(id: id) {
            pendingCloseID = id
        } else {
            Task { await closeSession(id: id, interrupt: false) }
        }
    }

    private func closeSession(id: String, interrupt: Bool) async {
        guard await store.close(id: id, interruptIfRunning: interrupt) else { return }
        approvals.removeAll(threadId: id)
        userInputs.removeAll(threadId: id)
        mcpElicitations.removeAll(threadId: id)
        sessions.activeSession?.composerDrafts.removeDraft(for: id)
    }
}
