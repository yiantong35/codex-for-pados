import SwiftUI

/// D8：对话滚动位置感知的纯决策（可单测，无 UI 依赖）。
enum ScrollAnchorPolicy {
    static func isNearBottom(distanceToBottom: CGFloat, threshold: CGFloat = 120) -> Bool {
        distanceToBottom <= threshold
    }
    static func shouldAutoScroll(isNearBottom: Bool) -> Bool { isNearBottom }
    static func shouldShowNewBelow(isNearBottom: Bool, contentDidGrow: Bool) -> Bool {
        !isNearBottom && contentDidGrow
    }
    static func contentDidGrow(previousHeight: CGFloat, currentHeight: CGFloat) -> Bool {
        previousHeight > 0 && currentHeight > previousHeight + 0.5
    }
}

private struct ConversationScrollMetrics: Equatable {
    var contentHeight: CGFloat = 0
    var distanceToBottom: CGFloat = 0
}

private struct ConversationScrollMetricsKey: PreferenceKey {
    static let defaultValue = ConversationScrollMetrics()
    static func reduce(value: inout ConversationScrollMetrics, nextValue: () -> ConversationScrollMetrics) {
        value = nextValue()
    }
}

/// 中栏对话流（设计 §3）：渲染选中 thread 的 ConversationState.items 流，
/// 含 agent 正文 / 命令执行卡 / 文件 diff 卡 / 用户消息气泡 / turn 状态指示。
/// 选中对话时用 connection.rpc 装配 ConversationStore，并 startObserving + resume。
/// composer（底部输入）在 Task 16 实现，此处先留只读占位。
struct ConversationView: View {
    @Environment(ConnectionStore.self) private var connection
    @Environment(ApprovalStore.self) private var approvals
    @Environment(UserInputStore.self) private var userInputs
    @Environment(McpElicitationStore.self) private var mcpElicitations
    @Environment(ActiveConversationHolder.self) private var activeConversation
    let threadId: String
    /// D1：是否绑定工作区审查状态（写入/清空 ActiveConversationHolder 并注册 resume）。
    /// 中栏主对话传 true（默认）；侧聊实例传 false，完全不碰 holder，隔离审查状态。
    var bindsWorkspaceState: Bool = true
    @State private var store: ConversationStore?
    /// D8：滚动位置感知（哨兵事件驱动，无轮询/定时器）。
    @State private var isNearBottom = true
    @State private var showNewBelow = false
    @State private var scrollMetrics = ConversationScrollMetrics()

    /// 属于当前线程的待处理审批卡（内联在对话流末尾）。
    private var threadApprovals: [ApprovalCard] {
        approvals.cards.filter { $0.threadId == threadId }
    }

    /// 同一 thread 一次只展示队首交互请求；完成后下一条自然出现。
    private var currentUserInput: UserInputCard? {
        userInputs.cards.first { $0.threadId == threadId }
    }

    private var currentMcpElicitation: McpElicitationCard? {
        mcpElicitations.cards.first { $0.threadId == threadId }
    }

    /// #4 手动重连重绑键：threadId + RPC 身份。ConversationStore 持 `let rpc`，仅 threadId 变化
    /// 不足以在**同一线程完整重连**（新 JSONRPCClient 实例）时重建 store → 旧 store 全打向已关闭
    /// client、订阅绑死旧流。把 rpc 身份并入键，令重连即重建（与 WorkspaceHost.rpcIdentity 同源）。
    private var convBindingKey: String {
        let rpcId = connection.rpc.map { "\(ObjectIdentifier($0))" } ?? "nil"
        return "\(threadId)|\(rpcId)"
    }

    var body: some View {
        GeometryReader { outer in
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
                    if let card = currentUserInput {
                        UserInputCardView(card: card).id(card.id)
                    }
                    if let card = currentMcpElicitation {
                        McpElicitationCardView(card: card).id(card.id)
                    }
                    ForEach(threadApprovals) { card in
                        ApprovalCardView(
                            card: card,
                            fileContext: ApprovalPresentation.fileContext(
                                for: card,
                                in: store?.state.items ?? []
                            )
                        )
                        .id(card.id)
                    }
                    if store?.state.isTurnRunning == true {
                        turnRunningIndicator.id(Self.turnIndicatorID)
                    }
                    // 稳定回底锚点；内容高度与底部距离由整个栈的几何快照统一上报。
                    Color.clear.frame(height: 1).id(Self.bottomSentinelID)
                }
                .padding()
                .background(GeometryReader { geometry in
                    Color.clear.preference(
                        key: ConversationScrollMetricsKey.self,
                        value: ConversationScrollMetrics(
                            contentHeight: geometry.size.height,
                            distanceToBottom: geometry.frame(in: .global).maxY - outer.frame(in: .global).maxY
                        )
                    )
                })
            }
            .onPreferenceChange(ConversationScrollMetricsKey.self) { metrics in
                let wasNearBottom = ScrollAnchorPolicy.isNearBottom(
                    distanceToBottom: Swift.max(0, scrollMetrics.distanceToBottom), threshold: 120
                )
                let grew = ScrollAnchorPolicy.contentDidGrow(
                    previousHeight: scrollMetrics.contentHeight, currentHeight: metrics.contentHeight
                )
                scrollMetrics = metrics
                isNearBottom = ScrollAnchorPolicy.isNearBottom(
                    distanceToBottom: Swift.max(0, metrics.distanceToBottom), threshold: 120
                )
                if grew {
                    if ScrollAnchorPolicy.shouldAutoScroll(isNearBottom: wasNearBottom) {
                        scrollToBottom(proxy)
                    } else if ScrollAnchorPolicy.shouldShowNewBelow(isNearBottom: wasNearBottom, contentDidGrow: true) {
                        showNewBelow = true
                    }
                } else if isNearBottom {
                    showNewBelow = false
                }
            }
            .overlay(alignment: .bottom) {
                if showNewBelow {
                    Button {
                        withAnimation { scrollToBottom(proxy); showNewBelow = false }
                    } label: {
                        Label("conv.newMessages", systemImage: "arrow.down.circle.fill")
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(.regularMaterial, in: Capsule())
                    }
                    .padding(.bottom, 8)
                    .accessibilityLabel(Text("conv.newMessages"))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: store?.state) { _, newValue in
            if bindsWorkspaceState { activeConversation.state = newValue }
        }
        .onChange(of: connection.phase) { _, newPhase in
            // reconnect-resync item 3：连接迁移到 .ready → drain 出站队列（补发离线期间缓存的输入）。
            if newPhase == .ready { store?.drainOutbox() }
        }
        .onDisappear {
            store?.stopObserving()
            if bindsWorkspaceState, activeConversation.contextIdentity == convBindingKey {
                activeConversation.state = nil; activeConversation.fetchFullDiff = nil; activeConversation.startReview = nil
                activeConversation.contextIdentity = nil
            }
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
        .task(id: convBindingKey) {
            guard let rpc = connection.rpc else { return }
            let s = ConversationStore(rpc: rpc, threadId: threadId)
            // reconnect-resync item 3：注入连接就绪信号，供 send 判定在线/离线分支。
            s.isReady = { [weak connection] in connection?.phase == .ready }
            await s.startObserving()   // 先完成订阅注册（async），再 resume，避免漏掉随后到达的事件
            await s.resume()        // session-management：恢复已有会话历史
            store = s
            defer { s.stopObserving() }   // D2：任务结束（threadId 变化/视图消失取消）即停本 store 订阅
            // D2：resume 注册不再受 bindsWorkspaceState 限制——主对话与每个侧聊各自 thread
            // 都需在重连后 rejoin 恢复；改 add/remove 精确配对，.task 结束/取消时注销自己的订阅，
            // 与 s.stopObserving() 两个 defer 并存。多订阅互不覆盖（Task 2 能力）。
            let resumeToken = connection.addResumeHandler { [weak s] in await s?.rejoinRunningThreads() }
            defer { connection.removeResumeHandler(resumeToken) }
            if bindsWorkspaceState {
                activeConversation.contextIdentity = convBindingKey
                // 审查面板「全量」数据源：注入拉取回调（gitDiffToRemote），供右栏按 cwd 拉全量 diff。
                activeConversation.fetchFullDiff = { [weak s] cwd in await s?.fetchFullDiff(cwd: cwd) }
                // 审查 tab AI 审查发起：注入 review/start 回调（设计 D4，对齐 fetchFullDiff 注入）。
                activeConversation.startReview = { [weak s] mode in await s?.startReview(mode: mode) ?? false }
            }
            // D2：保持本任务存活，把正文订阅生命周期绑定到 threadId。threadId 变化 / 视图消失时
            // SwiftUI 取消本 .task → Task.sleep 抛出 → defer 停止**本** store 的订阅，避免旧 observer
            // 残留消费通知流、唤醒主线程；切 N 次对话订阅数不累积。
            // 单次挂起，无周期唤醒（能耗）。使用有限大值（≈31.7 年）避免 .max 与当前时钟相加溢出即时返回。
            try? await Task.sleep(nanoseconds: 999_999_999_999_999_999)
        }
    }

    // MARK: - 子视图

    private static let turnIndicatorID = "__turn_running_indicator__"
    private static let bottomSentinelID = "__bottom_sentinel__"

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
            proxy.scrollTo(Self.bottomSentinelID, anchor: .bottom)
        }
    }
}
