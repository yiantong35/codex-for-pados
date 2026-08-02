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
        .onChange(of: connection.phase) { _, newPhase in
            // reconnect-resync item 3：连接迁移到 .ready → drain 出站队列（补发离线期间缓存的输入）。
            if newPhase == .ready { store?.drainOutbox() }
        }
        .onDisappear {
            store?.stopObserving()
            activeConversation.state = nil; activeConversation.fetchFullDiff = nil; activeConversation.startReview = nil
        }
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
            // reconnect-resync item 3：注入连接就绪信号，供 send 判定在线/离线分支。
            s.isReady = { [weak connection] in connection?.phase == .ready }
            await s.startObserving()   // 先完成订阅注册（async），再 resume，避免漏掉随后到达的事件
            await s.resume()        // session-management：恢复已有会话历史
            store = s
            defer { s.stopObserving() }   // D2：任务结束（threadId 变化/视图消失取消）即停本 store 订阅
            // 审查面板「全量」数据源：注入拉取回调（gitDiffToRemote），供右栏按 cwd 拉全量 diff。
            activeConversation.fetchFullDiff = { [weak s] cwd in await s?.fetchFullDiff(cwd: cwd) }
            // 审查 tab AI 审查发起：注入 review/start 回调（设计 D4，对齐 fetchFullDiff 注入）。
            activeConversation.startReview = { [weak s] mode in await s?.startReview(mode: mode) ?? false }
            // 首连/重连成功（.ready）→ 经官方 thread/loaded/list +
            // thread/resume(rejoin) 重建并重新订阅全部活跃 thread（§5），不依赖本地 seq/threadId。
            // 注：物理重连属 Phase 5，当前 relay transport 的 control() 为空流。
            connection.setResumeHandler { [weak s] in await s?.rejoinRunningThreads() }
            // D2：保持本任务存活，把正文订阅生命周期绑定到 threadId。threadId 变化 / 视图消失时
            // SwiftUI 取消本 .task → Task.sleep 抛出 → defer 停止**本** store 的订阅，避免旧 observer
            // 残留消费通知流、唤醒主线程；切 N 次对话订阅数不累积。
            // 单次挂起，无周期唤醒（能耗）。使用有限大值（≈31.7 年）避免 .max 与当前时钟相加溢出即时返回。
            try? await Task.sleep(nanoseconds: 999_999_999_999_999_999)
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
