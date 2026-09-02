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
    static func shouldAnimateScroll(userInitiated: Bool) -> Bool { userInitiated }
    static func contentDidGrow(previousHeight: CGFloat, currentHeight: CGFloat) -> Bool {
        previousHeight > 0 && currentHeight > previousHeight + 0.5
    }

    /// 回到最新浮钮（toolbar-status-and-jump-to-latest §2b）：离底即显纯 ↓ 图标态（显式命名可测）。
    static func shouldShowJumpToLatest(isNearBottom: Bool) -> Bool { !isNearBottom }

    /// 浮钮两态合成：新消息文案态（既有显示条件原样，零回归）> 纯 ↓ 图标态 > 隐藏。
    enum JumpAffordance: Equatable { case newMessages, jumpToLatest, hidden }
    static func jumpAffordance(showNewBelow: Bool, isNearBottom: Bool) -> JumpAffordance {
        if showNewBelow { return .newMessages }
        if shouldShowJumpToLatest(isNearBottom: isNearBottom) { return .jumpToLatest }
        return .hidden
    }

    /// 进会话初始定位到最新（spec 场景）：历史加载完成（.loaded）时一次性回底,
    /// 其余状态不动（loading 中内容未全、failed 留在错误现场）。
    static func shouldSnapToLatest(loadState: ConversationLoadState?) -> Bool {
        loadState == .loaded
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
    var outbox: ConversationOutbox? = nil
    /// D1：是否绑定工作区审查状态（写入/清空 ActiveConversationHolder 并注册 resume）。
    /// 中栏主对话传 true（默认）；侧聊实例传 false，完全不碰 holder，隔离审查状态。
    var bindsWorkspaceState: Bool = true
    /// 主工作区注入 Review 路由；侧聊即使误传，也会由隔离策略忽略。
    var onOpenReview: (() -> Void)? = nil
    var onOpenFile: ((String) -> Void)? = nil
    /// 侧聊由 SideChatStore 持有并观察的唯一 store；nil 时由本视图创建并拥有。
    var providedStore: ConversationStore? = nil
    var draftStore: ComposerDraftStore? = nil
    @State private var store: ConversationStore?
    /// D8：滚动位置感知（哨兵事件驱动，无轮询/定时器）。
    @State private var isNearBottom = true
    @State private var showNewBelow = false
    @State private var scrollMetrics = ConversationScrollMetrics()
    /// 进会话初始回底进行中（§2b「初始定位到最新」）：LazyVStack 高度为估算值,单次 scrollTo
    /// 落点不准（模拟器实证停在中段）——armed 期间每次几何回流都重锚,直到真正贴底移交给
    /// 既有近底自动跟随。事件驱动零轮询。
    @State private var initialSnapArmed = false

    static func allowsWorkspaceReviewNavigation(bindsWorkspaceState: Bool,
                                                hasAction: Bool) -> Bool {
        bindsWorkspaceState && hasAction
    }

    private var workspaceReviewAction: (() -> Void)? {
        guard Self.allowsWorkspaceReviewNavigation(
            bindsWorkspaceState: bindsWorkspaceState,
            hasAction: onOpenReview != nil)
        else { return nil }
        return onOpenReview
    }

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
        if let providedStore { return "provided|\(ObjectIdentifier(providedStore))" }
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
                        ItemCard(
                            item: item,
                            onOpenFile: onOpenFile,
                            isStreaming: store?.state.inFlightItemIds.contains(item.id) == true
                        )
                        .id(item.id)
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
            .scrollDismissesKeyboard(.interactively)
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
                if initialSnapArmed {
                    // 初始回底收敛：贴底即解除（移交近底自动跟随）,否则继续重锚。
                    if isNearBottom { initialSnapArmed = false } else { scrollToBottom(proxy) }
                }
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
            .onChange(of: store?.state.isTurnRunning) { _, _ in
                if ScrollAnchorPolicy.shouldAutoScroll(isNearBottom: isNearBottom) { scrollToBottom(proxy) }
            }
            .overlay(alignment: .bottom) {
                // 浮钮两态（§2b）：合成决策走纯函数；两态点击均回底并复位。
                // 贴底自动隐藏由既有 preference 回流更新 isNearBottom 驱动，零新增状态源（能耗）。
                switch ScrollAnchorPolicy.jumpAffordance(showNewBelow: showNewBelow, isNearBottom: isNearBottom) {
                case .newMessages:
                    Button {
                        scrollToBottom(proxy, userInitiated: true)
                        showNewBelow = false
                    } label: {
                        Label("conv.newMessages", systemImage: "arrow.down.circle.fill")
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(.regularMaterial, in: Capsule())
                    }
                    .padding(.bottom, 8)
                    .accessibilityLabel(Text("conv.newMessages"))
                case .jumpToLatest:
                    Button {
                        scrollToBottom(proxy, userInitiated: true)
                        showNewBelow = false
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 15, weight: .semibold))
                            .padding(10)
                            .background(.regularMaterial, in: Capsule())
                    }
                    .padding(.bottom, 8)
                    .accessibilityLabel(Text("conv.jumpToLatest"))
                case .hidden:
                    EmptyView()
                }
            }
            .onChange(of: store?.loadState, initial: true) { _, newValue in
                // 进会话初始定位到最新（spec 场景）：历史加载完成即回底并 arm 重锚收敛；
                // initial:true 兜住 providedStore 重挂时已是 .loaded 的路径。
                if ScrollAnchorPolicy.shouldSnapToLatest(loadState: newValue) {
                    initialSnapArmed = true
                    scrollToBottom(proxy)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay {
            if let store, store.loadState != .loaded {
                conversationLoadOverlay(store)
            }
        }
        .onChange(of: store.map { WorkspaceSummary.Snapshot(state: $0.state) }, initial: true) { _, newValue in
            if bindsWorkspaceState { activeConversation.state = newValue }
        }
        .onChange(of: store?.loadState) { _, newValue in
            if bindsWorkspaceState { activeConversation.loadState = newValue }
        }
        .onChange(of: connection.phase) { _, newPhase in
            // A reconnect must close the send window before .ready. The registered resume handler
            // reopens it only after authoritative thread state has been restored.
            if newPhase != .ready { store?.requireAuthoritativeRecovery() }
        }
        .onDisappear {
            if providedStore == nil { store?.stopObserving() }
            if bindsWorkspaceState, activeConversation.contextIdentity == convBindingKey {
                activeConversation.clearConversationBinding()
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let store {
                VStack(spacing: 0) {
                    progressCard(for: store.state)
                    ComposerView(
                        store: store,
                        draft: draftStore?.draft(for: threadId),
                        isEnabled: store.loadState == .loaded,
                        handlesWorkspaceShortcuts: bindsWorkspaceState
                    )
                }
            }
        }
        .navigationTitle("conv.title")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: convBindingKey) {
            let s: ConversationStore
            if let providedStore {
                s = providedStore
            } else {
                guard let rpc = connection.rpc else { return }
                s = ConversationStore(rpc: rpc, threadId: threadId, outbox: outbox ?? ConversationOutbox())
            }
            // reconnect-resync item 3：注入连接就绪信号，供 send 判定在线/离线分支。
            s.isReady = { [weak connection] in connection?.phase == .ready }
            s.requireAuthoritativeRecovery()
            await s.startObserving()
            store = s
            defer { s.stopObserving() }
            // D2：resume 注册不再受 bindsWorkspaceState 限制——主对话与每个侧聊各自 thread
            // 都需在重连后 rejoin 恢复；改 add/remove 精确配对，.task 结束/取消时注销自己的订阅，
            // 与 s.stopObserving() 两个 defer 并存。多订阅互不覆盖（Task 2 能力）。
            let resumeToken = connection.addResumeHandler(threadId: threadId) { [weak s] in
                await s?.recoverCurrentThread()
            }
            defer { connection.removeResumeHandler(resumeToken) }
            if bindsWorkspaceState {
                activeConversation.contextIdentity = convBindingKey
                // 状态区初值回写（store 装配先于 onChange 首触，防首帧空窗）。
                activeConversation.loadState = s.loadState
                // 刷新=resume 复用（design §2a）：用户显式动作，60s 有界超时（能耗约束内）。
                activeConversation.refresh = { [weak s] in await s?.resume() }
                // 审查面板「全量」数据源：注入拉取回调（gitDiffToRemote），供右栏按 cwd 拉全量 diff。
                activeConversation.fetchFullDiff = { [weak s] cwd in await s?.fetchFullDiff(cwd: cwd) }
                activeConversation.fetchGeneration &+= 1
                // 审查 tab AI 审查发起：注入 review/start 回调（设计 D4，对齐 fetchFullDiff 注入）。
                activeConversation.startReview = { [weak s] mode in await s?.startReview(mode: mode) ?? false }
                activeConversation.applyThreadSnapshot = { [weak s] threadId, result in
                    guard s?.threadId == threadId else { return }
                    s?.applyAuthoritativeThreadSnapshot(result)
                }
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
    private func conversationLoadOverlay(_ store: ConversationStore) -> some View {
        switch store.loadState {
        case .idle, .loading:
            ProgressView("conv.loading")
                .padding(16)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        case .failed:
            ContentUnavailableView {
                Label("conv.loadFailed", systemImage: "exclamationmark.triangle")
            } actions: {
                Button("common.retry") { Task { await store.resume() } }
                    .buttonStyle(.borderedProminent)
            }
        case .loaded:
            EmptyView()
        }
    }

    @ViewBuilder
    private func progressCard(for state: ConversationState) -> some View {
        let progress = WorkspaceSummary.planProgress(in: state)
        let diff = WorkspaceSummary.diffLineCounts(in: state)
        if !progress.isEmpty || !diff.isEmpty {
            ProgressCardBar(progress: progress, diff: diff,
                            isRunning: state.isTurnRunning,
                            onTapFiles: workspaceReviewAction)
            .padding(.bottom, 6)
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, userInitiated: Bool = false) {
        if ScrollAnchorPolicy.shouldAnimateScroll(userInitiated: userInitiated) {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(Self.bottomSentinelID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(Self.bottomSentinelID, anchor: .bottom)
        }
    }
}
