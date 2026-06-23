import SwiftUI

/// 中栏对话流（设计 §3）：渲染选中 thread 的 ConversationState.items 流，
/// 含 agent 正文 / 命令执行卡 / 文件 diff 卡 / 用户消息气泡 / turn 状态指示。
/// 选中对话时用 connection.rpc 装配 ConversationStore，并 startObserving + resume。
/// composer（底部输入）在 Task 16 实现，此处先留只读占位。
struct ConversationView: View {
    @Environment(ConnectionStore.self) private var connection
    @Environment(ApprovalStore.self) private var approvals
    @Environment(ActiveConversationHolder.self) private var activeConversation
    let threadId: String
    @State private var store: ConversationStore?

    /// 属于当前线程的待处理审批卡（内联在对话流末尾）。
    private var threadApprovals: [ApprovalCard] {
        approvals.cards.filter { $0.threadId == threadId }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let count = store?.state.commandCount, count > 0 {
                        Label("conv.commandsRun \(count)", systemImage: "terminal")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(store?.state.items ?? []) { item in
                        ItemCard(item: item).id(item.id)
                    }
                    ForEach(threadApprovals) { card in
                        ApprovalCardView(card: card).id(card.id)
                    }
                    if store?.state.isTurnRunning == true {
                        turnRunningIndicator.id(Self.turnIndicatorID)
                    }
                }
                .padding()
            }
            .onChange(of: store?.state.items.count) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: store?.state.isTurnRunning) { _, _ in
                scrollToBottom(proxy)
            }
        }
        .onChange(of: store?.state) { _, newValue in
            activeConversation.state = newValue
        }
        .onDisappear { activeConversation.state = nil }
        .safeAreaInset(edge: .bottom) {
            if let store {
                VStack(spacing: 0) {
                    progressCard(for: store.state)
                    ComposerView(store: store)
                }
            }
        }
        .navigationTitle("conv.title")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if store?.state.isTurnRunning == true {
                    Label("conv.running", systemImage: "circle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if store != nil {
                    Label("conv.idle", systemImage: "checkmark.circle")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task(id: threadId) {
            guard let rpc = connection.rpc else { return }
            let s = ConversationStore(rpc: rpc, threadId: threadId)
            await s.startObserving()   // 先完成订阅注册（async），再 resume，避免漏掉随后到达的事件
            await s.resume()        // session-management：恢复已有会话历史
            store = s
            // snapshot-needed 控制信号 → 重建当前活跃 thread（缺口过大时由 WSTransport 上抛）。
            connection.setResumeHandler { [weak s] in await s?.resume() }
        }
    }

    // MARK: - 子视图

    private static let turnIndicatorID = "__turn_running_indicator__"

    private var turnRunningIndicator: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("conv.generating").font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func progressCard(for state: ConversationState) -> some View {
        let progress = WorkspaceSummary.planProgress(in: state)
        let diff = WorkspaceSummary.diffLineCounts(in: state)
        if !progress.isEmpty || !diff.isEmpty {
            ProgressCardBar(progress: progress, diff: diff) {
                activeConversation.requestRightPanel = true
            }
            .padding(.bottom, 6)
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            if store?.state.isTurnRunning == true {
                proxy.scrollTo(Self.turnIndicatorID, anchor: .bottom)
            } else if let last = store?.state.items.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }
}
