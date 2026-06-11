import SwiftUI

/// 中栏对话流（设计 §3）：渲染选中 thread 的 ConversationState.items 流，
/// 含 agent 正文 / 命令执行卡 / 文件 diff 卡 / 用户消息气泡 / turn 状态指示。
/// 选中对话时用 connection.rpc 装配 ConversationStore，并 startObserving + resume。
/// composer（底部输入）在 Task 16 实现，此处先留只读占位。
struct ConversationView: View {
    @Environment(ConnectionStore.self) private var connection
    let threadId: String
    @State private var store: ConversationStore?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(store?.state.items ?? []) { item in
                        ItemCard(item: item).id(item.id)
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
        .safeAreaInset(edge: .bottom) {
            composerPlaceholder
        }
        .navigationTitle("对话")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if store?.state.isTurnRunning == true {
                    Label("进行中", systemImage: "circle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if store != nil {
                    Label("空闲", systemImage: "checkmark.circle")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task(id: threadId) {
            guard let rpc = connection.rpc else { return }
            let s = ConversationStore(rpc: rpc, threadId: threadId)
            s.startObserving()
            await s.resume()        // session-management：恢复已有会话历史
            store = s
        }
    }

    // MARK: - 子视图

    private static let turnIndicatorID = "__turn_running_indicator__"

    private var turnRunningIndicator: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("生成中…").font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Task 16 替换为真正的 ComposerView(store:)。此处只读占位（不实现发送）。
    private var composerPlaceholder: some View {
        HStack {
            Text("输入框将在后续任务接入")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(12)
        .background(.bar)
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
