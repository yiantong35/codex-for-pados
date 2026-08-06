import SwiftUI

/// 侧聊面板（design D3/D4）：顶部侧聊选择器（多侧聊切换条 + 「开始侧聊」+ 每条关闭）+
/// 选中侧聊的完整 ConversationView（复用中栏视图：消息流 + 输入 + 审批卡，窄栏不特殊处理）。
/// 无主对话（mainThreadId 空）→ 空态提示、「开始侧聊」禁用、不 fork。
struct SideChatView: View {
    @Bindable var store: SideChatStore
    /// 当前主对话 threadId：侧聊从它 fork。nil/空 → 无主对话空态。
    var mainThreadId: String?

    private var hasMainThread: Bool {
        !(mainThreadId ?? "").isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            selectorBar
            Divider()
            content
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
                .disabled(!hasMainThread)

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
            Button { store.close(id: session.id) } label: {
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
                  let session = store.sessions.first(where: { $0.id == id }) {
            ConversationView(
                threadId: session.conversation.threadId,
                bindsWorkspaceState: false,
                providedStore: session.conversation
            )
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
}
