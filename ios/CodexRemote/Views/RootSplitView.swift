import SwiftUI
import Observation

/// 当前活跃会话状态的共享持有者：ConversationView 写入最新 state，
/// 顶栏摘要 popover 读出用于派生 diff/plan/tasks（cwd 仍取选中 ThreadSummary）。
@Observable
@MainActor
final class ActiveConversationHolder {
    var state: WorkspaceSummary.Snapshot?
    var contextIdentity: String?
    /// 拉取远端全量 diff 的回调（由持有 ConversationStore 的 ConversationView 注入）。
    /// 审查面板切到「全量」时调用；未接线（nil）时返回 nil，面板降级空态。
    var fetchFullDiff: ((_ cwd: String) async -> String?)?
    /// fetch 回调/RPC 绑定代际。重连或重新注入时递增，令 Full Diff 缓存失效并重试。
    var fetchGeneration = 0
    /// 发起 AI 审查的回调（由持有 ConversationStore 的 ConversationView 注入，设计 D4）。
    /// 审查 tab 的「本轮/全量」发起入口调用；未接线（nil）→ 入口禁用。返回是否成功发出。
    var startReview: ((_ mode: ReviewSourceMode) async -> Bool)?
    /// Apply an authoritative thread snapshot such as the result of thread/rollback.
    var applyThreadSnapshot: ((_ threadId: String, _ result: [String: Any]) -> Void)?
    /// 当前会话加载状态（nil=无会话选中 → 工具栏状态区整块隐藏）。ConversationView 回写。
    var loadState: ConversationLoadState?
    /// 刷新当前会话（resume 复用）的回调；loading 期间由视图层禁用防抖。
    var refresh: (() async -> Void)?

    /// 会话绑定统一清理（换绑 onDisappear / 取消选中 reconcile 共用，防新字段漏清）。
    func clearConversationBinding() {
        state = nil
        loadState = nil
        refresh = nil
        fetchFullDiff = nil
        startReview = nil
        applyThreadSnapshot = nil
        fetchGeneration &+= 1
        contextIdentity = nil
    }
}

/// 每台机器独立的工作区 UI 上下文。实例由 `Session` 持有，因此切走机器导致
/// `RootSplitView` 重建时，选中会话和面板状态仍会随该机器保留。
@Observable
@MainActor
final class WorkspaceSessionState {
    var selectedThreadId: String?
    let conversationOutboxes: ConversationOutboxRegistry
    let layout: WorkspaceLayoutStore
    var bottomHeight: CGFloat
    var rightPanelTab: RightPanelTab

    init(initialRightOpen: Bool = false, initialBottomOpen: Bool = false,
         conversationOutboxes: ConversationOutboxRegistry = ConversationOutboxRegistry()) {
        self.conversationOutboxes = conversationOutboxes
        layout = WorkspaceLayoutStore(showRight: initialRightOpen, showBottom: initialBottomOpen)
        bottomHeight = WorkspaceMetrics.bottomPanelIdealHeight
        rightPanelTab = .review
    }
}

/// 主界面（复刻 Codex desktop 五窗口工作区骨架，自绘三栏重构 custom-resizable-columns）：
/// 顶栏使用 NavigationStack 的系统 toolbar；摘要用常驻 overlay，挂在自绘三栏容器上。
/// - 左边栏 = ResizableColumns 左列（条件渲染，leftVisible 承接，D5）；右边栏 = 右列（showRight 承接）。
/// - 下边栏 = VStack 底部兄弟槽：横跨左+中+右、把三栏挤压上移（design D2，布局翻转）。
/// - 摘要 = :≡ 按钮触发的常驻悬浮浮层（overlay，design D2），非占列。
struct RootSplitView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(ConnectionStore.self) private var connection
    @Environment(ProjectsStore.self) private var projects
    @Environment(EnvironmentInspectorModel.self) private var envInspector
    @Environment(FileBrowserStore.self) private var fileBrowser
    @Environment(SideChatStore.self) private var sideChat
    // 真实系统深浅值：theme=.system 时本视图跟随系统，此值即真实系统外观，传给设置 sheet
    // 以正确解析 .system（规避 sheet .preferredColorScheme(nil) 无法重置强制值）。
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(SessionsManager.self) private var sessions
    @State private var workspaceState: WorkspaceSessionState

    /// 当前活跃会话 state 的共享持有者：ConversationView 写入、摘要 popover 读出。
    @State private var activeConversation = ActiveConversationHolder()

    /// 列宽 session 级持久化（D7）：拖动 save / 切 tab 读回 / 冷启动恢复。
    @State private var columnWidths = ColumnWidthStore()

    @State private var fileOpenTask: Task<Void, Never>?
    @State private var operationError: String?
    @State private var selectionReconcileTask: Task<Void, Never>?
    @State private var isReconcilingSelection = false
    @State private var pendingSelectionReconcileIDs: Set<String>?
    @State private var latestSelectionReconcileIDs: Set<String>?
    @State private var showRePairing = false
    @State private var connectionFailureDetails: String?
    @State private var manualReconnectInProgress = false
    // review P2-2：摘要浮层随字号缩放，避免大档裁切。
    @ScaledMetric private var summaryWidth: CGFloat = 340
    @ScaledMetric private var summaryMaxHeight: CGFloat = 480
    /// 便利初始化：允许注入面板初始展开态（供快照测试覆盖全开布局）。
    init(initialRightOpen: Bool = false, initialBottomOpen: Bool = false,
         workspaceState: WorkspaceSessionState? = nil) {
        _workspaceState = State(initialValue: workspaceState ?? WorkspaceSessionState(
            initialRightOpen: initialRightOpen,
            initialBottomOpen: initialBottomOpen))
    }

    private var layout: WorkspaceLayoutStore { workspaceState.layout }
    private var selectedThreadId: String? { workspaceState.selectedThreadId }

    private var selectedThread: ThreadSummary? {
        guard let id = selectedThreadId else { return nil }
        return projects.allThreadsSorted.first { $0.id == id }
    }

    // 批次⑤：摘要打开/切换会话/连接就绪时触发环境信息刷新的 key（含连接态避免冷启动漏刷 I2）。
    private var summaryEnvKey: String { "\(layout.showSummary)-\(selectedThreadId ?? "")-\(connection.phase == .ready)" }

    var body: some View {
        @Bindable var layout = layout
        NavigationStack {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    resizableColumns
                    // 摘要：常驻悬浮浮层（design D2 改）。用 overlay 而非 .popover，故点击别处不收回，
                    // 仅由系统工具栏摘要按钮显隐；浮层位于工具栏下方的工作区内容层。
                    .overlay(alignment: .topTrailing) {
                        if layout.showSummary {
                            GeometryReader { geometry in
                                SummaryPopoverView(state: activeConversation.state, thread: selectedThread, env: envInspector,
                                                   onOpenReview: { layout.requestRightPanel(.review) })
                                    .frame(width: min(summaryWidth, max(0, geometry.size.width - 24)))
                                    .task(id: summaryEnvKey) {
                                        if connection.phase == .ready, let rpc = connection.rpc {
                                            envInspector.attach(rpc: rpc)
                                            await envInspector.refresh(cwd: selectedThread?.cwd)
                                        }
                                    }
                                    .frame(maxHeight: summaryMaxHeight)
                                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
                                    .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
                                    .padding(.top, 8)
                                    .padding(.trailing, 12)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                    }
                    // 下栏：VStack 底部兄弟槽，横跨三栏并把内容挤压上移。
                    if layout.showBottom {
                        Divider()
                        BottomPanelView(height: Binding(
                            get: { workspaceState.bottomHeight },
                            set: { workspaceState.bottomHeight = $0 }
                        ), maximumHeight: WorkspaceMetrics.bottomPanelMaximumHeight(
                            containerHeight: geometry.size.height
                        ), cwd: selectedThread?.cwd)
                        .transition(.move(edge: .bottom))
                    }
                }
                .onAppear { layout.updateContainerWidth(geometry.size.width) }
                .onChange(of: geometry.size.width) { _, width in
                    layout.updateContainerWidth(width)
                }
                // 连接横幅（connection-banner-toast）：顶部浮层化——原为 VStack 条件分支,
                // 显隐会把三栏内容整体推移(周期性重连时布局跳动)。overlay 布局零位移,
                // 三态语义/按钮/判定逻辑零改动;胶囊外观+过渡动画在 ConnectionBanner 内。
                .overlay(alignment: .top) {
                    if let state = effectiveBannerState {
                        ConnectionBanner(
                            state: state,
                            onReconnect: beginManualReconnect,
                            onShowDetails: { connectionFailureDetails = $0 },
                            onRePair: { showRePairing = true }
                        )
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(.snappy(duration: 0.25), value: effectiveBannerState == nil)
            }
            .toolbar {
                WorkspaceToolbar(
                    layout: layout,
                    reduceMotion: reduceMotion,
                    conversation: activeConversation
                )
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .background { ShortcutLayer(layout: layout) }   // T10：隐藏快捷键层挂稳定独立视图（不随 body 重算重建）
        .environment(activeConversation)
        // 设置页用 fullScreenCover 而非 sheet：iPad regular 宽度下 .sheet 会渲染成居中的 form-sheet
        // （悬浮小 dialog，形态与 iPhone/compact 的全屏 sheet 不一致）；且 form-sheet 是 elevated 语境，
        // 分组 List 的 secondarySystemGroupedBackground 首帧按 base 解析、一个 runloop 后才转 elevated，
        // 表现为「黑底→灰底」中间态（真机实证）。fullScreenCover 全屏、恒定 base level，两问题一并消除。
        .fullScreenCover(isPresented: $layout.showSettings) { SettingsPageView(systemColorScheme: systemColorScheme) }
        .sheet(isPresented: $showRePairing) {
            NavigationStack {
                RelayPairingImportView(
                    replacingMachineID: sessions.activeSessionId,
                    onImported: { showRePairing = false }
                )
            }
        }
        .alert("connection.details.title", isPresented: Binding(
            get: { connectionFailureDetails != nil },
            set: { if !$0 { connectionFailureDetails = nil } }
        )) {
            Button("common.ok", role: .cancel) { connectionFailureDetails = nil }
        } message: {
            Text(verbatim: connectionFailureDetails ?? "")
        }
        .alert("operation.failed.title", isPresented: Binding(
            get: { operationError != nil },
            set: {
                if !$0 {
                    operationError = nil
                    pendingSelectionReconcileIDs = nil
                }
            }
        )) {
            if let ids = pendingSelectionReconcileIDs {
                Button("sidebar.retry") {
                    pendingSelectionReconcileIDs = nil
                    operationError = nil
                    reconcileSelectedThread(availableIDs: ids)
                }
            }
            Button("common.ok", role: .cancel) {
                operationError = nil
                pendingSelectionReconcileIDs = nil
            }
        } message: {
            Text(operationError ?? "")
        }
        .onChange(of: sessions.activeSessionId) { _, newId in
            loadColumnWidths(for: newId)
        }
        .onChange(of: selectedThreadId) { _, newId in
            fileOpenTask?.cancel()
            sideChat.setParentThread(newId)
        }
        .onChange(of: projects.allThreadsSorted.map(\.id)) { _, ids in
            reconcileSelectedThread(availableIDs: Set(ids))
        }
        .onChange(of: projects.loadState) { _, _ in
            reconcileSelectedThread(availableIDs: Set(projects.allThreadsSorted.map(\.id)))
        }
        .onChange(of: connection.phase) { _, phase in
            if phase == .ready || phase.isFailure {
                manualReconnectInProgress = false
            }
        }
        .task {
            loadColumnWidths(for: sessions.activeSessionId)
        }
    }

    private var effectiveBannerState: ConnectionBannerState? {
        if manualReconnectInProgress {
            switch connection.phase {
            case .connecting, .initializing: return .reconnecting
            default: break
            }
        }
        return connection.bannerState
    }

    private func beginManualReconnect() {
        manualReconnectInProgress = true
        connection.reconnect()
    }

    // MARK: - 自绘三栏（custom-resizable-columns，替换 NavigationSplitView + .inspector）

    private var resizableColumns: some View {
        @Bindable var layout = layout
        return ResizableColumns(
            leftWidth: $layout.leftWidth,
            rightWidth: $layout.rightWidth,
            leftVisible: layout.leftVisible,
            rightVisible: layout.showRight,
            lastRequested: layout.lastRequested,
            onResizeEnded: { saveColumnWidths() },
            onDismissOverlay: { side in
                switch side {
                case .left: layout.leftVisible = false
                case .right: layout.showRight = false
                case .none: break
                }
            }
        ) {
            SidebarView(selectedThreadId: Binding(
                get: { workspaceState.selectedThreadId },
                set: { workspaceState.selectedThreadId = $0 }
            ))
        } center: {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } right: {
            RightPanelContainerView(
                cwd: selectedThread?.cwd,
                mainThreadId: selectedThreadId,
                selectedTab: Binding(
                    get: { workspaceState.rightPanelTab },
                    set: { workspaceState.rightPanelTab = $0 }
                )
            )
                // 右栏在自绘列内仍显式注入环境（对齐原 .inspector 注入），
                // 否则 RightPanelContainerView 读环境时运行时崩溃。
                .environment(activeConversation)
                .environment(layout)   // 设计 D6：右栏跳转信号载体
        }
    }

    // MARK: - 列宽持久化数据流（D7）

    private func saveColumnWidths() {
        guard let id = sessions.activeSessionId else { return }
        columnWidths.save(machineId: id, left: layout.leftWidth, right: layout.rightWidth)
    }

    private func loadColumnWidths(for id: UUID?) {
        guard let id else { return }
        let preferred = columnWidths.preferredWidths(for: id)
        layout.leftWidth = preferred.left
        layout.rightWidth = preferred.right
    }

    @ViewBuilder private var content: some View {
        if let id = selectedThreadId {
            ConversationView(
                threadId: id,
                outbox: workspaceState.conversationOutboxes.outbox(for: id),
                onOpenReview: { layout.requestRightPanel(.review) },
                onOpenFile: { path in openFileInBrowser(path) },
                draftStore: sessions.activeSession?.composerDrafts
            )
            .id(id)
        } else {
            VStack(spacing: 0) {
                WorkspaceHeader { Color.clear }
                Divider()
                WorkspaceEmptyState(
                    title: "split.selectConversation",
                    systemImage: "bubble.left.and.bubble.right"
                )
            }
        }
    }

    private func openFileInBrowser(_ path: String) {
        layout.requestRightPanel(.files)
        guard connection.phase == .ready, let rpc = connection.rpc else { return }
        let cwd = selectedThread?.cwd
        let threadId = selectedThreadId
        let resolvedPath = path.hasPrefix("/") ? path : [cwd, path].compactMap { $0 }.joined(separator: "/")
        fileBrowser.attach(rpc: rpc)
        fileOpenTask?.cancel()
        fileOpenTask = Task {
            await fileBrowser.setRoot(cwd)
            guard !Task.isCancelled, selectedThreadId == threadId else { return }
            await fileBrowser.openFile(resolvedPath)
        }
    }

    private func reconcileSelectedThread(availableIDs: Set<String>) {
        if isReconcilingSelection {
            latestSelectionReconcileIDs = availableIDs
            return
        }
        guard pendingSelectionReconcileIDs == nil else { return }
        let resolved = Self.resolvedSelection(
            current: workspaceState.selectedThreadId,
            availableIDs: availableIDs,
            loadState: projects.loadState
        )
        guard workspaceState.selectedThreadId != resolved else { return }
        selectionReconcileTask?.cancel()
        let expectedSelection = workspaceState.selectedThreadId
        let sideChatIDs = sideChat.sessions.map(\.id)
        isReconcilingSelection = true
        selectionReconcileTask = Task {
            defer {
                isReconcilingSelection = false
                if let latest = latestSelectionReconcileIDs {
                    latestSelectionReconcileIDs = nil
                    reconcileSelectedThread(availableIDs: latest)
                }
            }
            let resetResult = await sideChat.reset().value
            guard !Task.isCancelled, workspaceState.selectedThreadId == expectedSelection else { return }
            guard case .reset = resetResult else {
                if case .interruptFailed(let ids) = resetResult {
                    pendingSelectionReconcileIDs = availableIDs
                    operationError = cleanupFailureMessage(ids)
                }
                return
            }
            pendingSelectionReconcileIDs = nil
            for id in sideChatIDs {
                sessions.activeSession?.approvals.removeAll(threadId: id)
                sessions.activeSession?.userInputs.removeAll(threadId: id)
                sessions.activeSession?.mcpElicitations.removeAll(threadId: id)
            }
            workspaceState.selectedThreadId = resolved
            activeConversation.clearConversationBinding()
            fileOpenTask?.cancel()
            await fileBrowser.setRoot(nil)
        }
    }

    private func cleanupFailureMessage(_ ids: [String]) -> String {
        String.localizedStringWithFormat(
            L10n.string("sideChat.cleanupFailed %@", locale: LocaleManager.currentLocale),
            ids.joined(separator: ", ")
        )
    }

    static func resolvedSelection(current: String?, availableIDs: Set<String>,
                                  loadState: ProjectsLoadState) -> String? {
        guard loadState == .loaded, let current else { return current }
        return availableIDs.contains(current) ? current : nil
    }

    /// Compatibility predicate used by lifecycle tests and callers that need to decide whether
    /// transient side-chat interaction state is safe to discard after reset.
    static func shouldClearSideChatInteractionState(after result: SideChatResetResult) -> Bool {
        result == .reset
    }
}

/// System toolbar content installed on the navigated workspace content.
struct WorkspaceToolbar: ToolbarContent {
    let layout: WorkspaceLayoutStore
    let reduceMotion: Bool
    /// 状态胶囊数据源（design §2a）：读 loadState/isTurnRunning 渲染，nil 整块隐藏。
    let conversation: ActiveConversationHolder

    /// 工具栏图标尺寸随 Dynamic Type 缩放（默认 21，更大档会自动放大），
    /// 唯一尺寸来源：4 个布局按钮 + 齿轮 + 刷新共用，避免分段容器放大而图标不缩放的断层。
    @ScaledMetric(relativeTo: .body) private var toolbarIconSize: CGFloat = 21

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            TabBarView()
        }

        // 状态胶囊+刷新（toolbar-status-and-jump-to-latest §2a）：声明在 4 图标组之前 →
        // 同 ToolbarContent 内顺序确定。刷新钮=选中会话即常驻；胶囊=仅加载中/失败两态
        // （运行/空闲不显示,侧栏徽标已覆盖——用户 2026-09-02 定案）。
        // ToolbarItemGroup 独立子项（单 ToolbarItem 塞 HStack 会被导航栏吞掉按钮,模拟器实证）。
        if conversation.loadState != nil {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let status = ConversationStatusPresentation.descriptor(loadState: conversation.loadState) {
                    statusCapsule(status)
                }
                refreshButton
            }
        }

        ToolbarItemGroup(placement: .topBarTrailing) {
            ControlGroup {
                panelToolbarButton(
                    symbol: "rectangle.leadinghalf.inset.filled",
                    label: "workspace.leftPanel.toggle",
                    isOn: layout.leftVisible
                ) { animate { layout.toggleLeftPanel() } }
                panelToolbarButton(
                    symbol: "rectangle.bottomthird.inset.filled",
                    label: "workspace.bottomPanel.toggle",
                    isOn: layout.showBottom
                ) { animate { layout.showBottom.toggle() } }
                panelToolbarButton(
                    symbol: "list.bullet",
                    label: "workspace.summary.toggle",
                    isOn: layout.showSummary
                ) { animate { layout.showSummary.toggle() } }
                panelToolbarButton(
                    symbol: "rectangle.trailinghalf.inset.filled",
                    label: "workspace.rightPanel.toggle",
                    isOn: layout.showRight
                ) { animate { layout.toggleRightPanel() } }
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            Button { layout.showSettings = true } label: {
                toolbarLabel(symbol: "gearshape", label: "settings.accessibility")
            }
        }
    }

    /// 刷新按钮：resume 复用（holder.refresh 注入），loading 禁用防抖。
    private var refreshButton: some View {
        Button {
            Task { await conversation.refresh?() }
        } label: {
            toolbarLabel(symbol: "arrow.clockwise", label: "conv.refresh")
        }
        .disabled(ConversationStatusPresentation.shouldDisableRefresh(loadState: conversation.loadState))
        .accessibilityLabel(Text("conv.refresh"))
    }

    /// 状态胶囊：限幅+单行截断（最大字号档不溢出、不挤压相邻工具栏项）。
    /// 不用 Label——导航栏环境会强制 Label 走 iconOnly（文字被吞，模拟器实证），
    /// HStack{Image+Text} 绕开该环境注入。
    private func statusCapsule(_ status: ConversationStatusPresentation.Descriptor) -> some View {
        HStack(spacing: 4) {
            Image(systemName: status.symbol)
            Text(LocalizedStringKey(status.key))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.caption)
        .foregroundStyle(status.tint.color)
        .frame(maxWidth: 180)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
    }

    private func toolbarLabel(
        symbol: String,
        label: LocalizedStringKey,
        selected: Bool = false
    ) -> some View {
        Label(label, systemImage: symbol)
            .labelStyle(.iconOnly)
            .font(.system(size: toolbarIconSize, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
            .frame(minWidth: 44, minHeight: 44)   // ≥44pt 点击区，随图标内容自适应放大
            .contentShape(Rectangle())
    }

    private func panelToolbarButton(
        symbol: String,
        label: LocalizedStringKey,
        isOn: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) { toolbarLabel(symbol: symbol, label: label, selected: isOn) }
            .accessibilityValue(Text(isOn ? "workspace.panel.shown" : "workspace.panel.hidden"))
            .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func animate(_ changes: () -> Void) {
        if reduceMotion { changes() }
        else { withAnimation { changes() } }
    }
}

private extension ConnectionPhase {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

struct ConnectionBanner: View {
    let state: ConnectionBannerState
    let onReconnect: () -> Void
    let onShowDetails: (String) -> Void
    let onRePair: () -> Void

    // connection-banner-toast：整宽横条 → 胶囊浮层（挂载方已 overlay 化,此处只管外观）。
    // 三态内容/按钮零改动;maxWidth 限宽避免占满整行,材质+描边+阴影浮于内容之上。
    var body: some View {
        bannerContent
        .font(.subheadline)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(minHeight: 44)
        .frame(maxWidth: 520)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
        .padding(.top, 8)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var bannerContent: some View {
        switch state {
        case .reconnecting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("root.reconnecting")
                Spacer(minLength: 0)
            }
            .frame(minHeight: 44)
        case .failed(let reason):
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    statusLabel("connection.banner.disconnected")
                    Spacer(minLength: 4)
                    failureActions(reason)
                }
                VStack(alignment: .leading, spacing: 0) {
                    statusLabel("connection.banner.disconnected")
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        failureActions(reason)
                    }
                }
            }
        case .rePairingRequired(let reason):
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    statusText(reason)
                    Spacer(minLength: 4)
                    rePairButton
                }
                VStack(alignment: .leading, spacing: 0) {
                    statusText(reason)
                    rePairButton.frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
    }

    private func statusLabel(_ key: LocalizedStringKey) -> some View {
        Label(key, systemImage: "wifi.slash")
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func statusText(_ value: String) -> some View {
        Label {
            Text(verbatim: value)
        } icon: {
            Image(systemName: "wifi.slash")
        }
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func failureActions(_ reason: String) -> some View {
        HStack(spacing: 4) {
            Button { onShowDetails(reason) } label: {
                Image(systemName: "info.circle")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("connection.details"))
            Button("connection.reconnect", action: onReconnect)
                .frame(minHeight: 44)
        }
    }

    private var rePairButton: some View {
        Button("connection.rePair", action: onRePair)
            .frame(minHeight: 44)
    }
}

// MARK: - 隐藏快捷键层（T10 / 设计 D5）

/// 隐藏快捷键宿主，抽成独立 View（批次 D 修复）：
/// 1. 稳定性——挂在 RootSplitView `.background` 里的独立视图，仅依赖 layout/sessions/shortcuts，
///    不随 RootSplitView.body 每次重算（分隔线拖动等）而重建，快捷键注册不抖动。
/// 2. 投递安全——不再用 `.hidden()`（会把子树移出无障碍**与**交互树，可能连带丢掉
///    `.keyboardShortcut`/UIKeyCommand 注册）。改用 `.opacity(0)` + 零尺寸 frame：按钮仍留在
///    响应链里（外接键盘可触发），再叠 `.accessibilityHidden(true)` 把 21 个空标签按钮挡在
///    VoiceOver 之外（`.hidden()` 不再代劳后必须显式补）。
///
/// 每动作一个隐藏 Button + `.keyboardShortcut(shortcuts.combo(for:).keyboardShortcut)`；
/// `shortcuts` 变化 → 本视图重算 → 快捷键动态刷新（无需手写 UIKeyCommand）。
struct ShortcutLayer: View {
    let layout: WorkspaceLayoutStore
    @Environment(SessionsManager.self) private var sessions
    @Environment(ShortcutStore.self) private var shortcuts
    @Environment(TextScaleManager.self) private var textScale
    // U1：本层挂在根 .dynamicTypeSize 注入之下，读到的即当前**有效**档，
    // 供「跟随系统」下放大/缩小取基线（baseline(effective:)）。
    @Environment(\.dynamicTypeSize) private var effectiveSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// ⌘1..⌘9 对应的动作（下标 i → 机器数组第 i 项）。
    private static let tabActions: [ShortcutAction] =
        [.tab1, .tab2, .tab3, .tab4, .tab5, .tab6, .tab7, .tab8, .tab9]

    var body: some View {
        Group {
            // 面板（workspace）
            Button("") { animate { layout.toggleLeftPanel() } }
                .keyboardShortcut(shortcuts.combo(for: .toggleLeftPanel).keyboardShortcut)
            Button("") { animate { layout.toggleRightPanel() } }
                .keyboardShortcut(shortcuts.combo(for: .toggleRightPanel).keyboardShortcut)
            Button("") { animate { layout.showBottom.toggle() } }
                .keyboardShortcut(shortcuts.combo(for: .toggleBottomPanel).keyboardShortcut)
            Button("") { animate { layout.showSummary.toggle() } }
                .keyboardShortcut(shortcuts.combo(for: .toggleSummary).keyboardShortcut)
            Button("") { layout.showSettings = true }
                .keyboardShortcut(shortcuts.combo(for: .openSettings).keyboardShortcut)

            // 右栏跳转 / 全屏 + Tab + 文字缩放——各拆子 Group，规避 ViewBuilder 单层 10 子视图上限
            rightPanelShortcutButtons
            tabShortcutButtons
            textScaleButtons
        }
        // 投递安全的「隐形但仍注册」组合（替代 .hidden()）：
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    // 右栏跳转 / 全屏（workspace）——requestRightPanel 先开右栏再发信号
    @ViewBuilder
    private var rightPanelShortcutButtons: some View {
        Group {
            Button("") { layout.requestRightPanel(.review) }
                .keyboardShortcut(shortcuts.combo(for: .rightPanelReview).keyboardShortcut)
            Button("") { layout.requestRightPanel(.files) }
                .keyboardShortcut(shortcuts.combo(for: .rightPanelFiles).keyboardShortcut)
            Button("") { layout.requestRightPanel(.sideChat) }
                .keyboardShortcut(shortcuts.combo(for: .rightPanelSideChat).keyboardShortcut)
            Button("") { layout.requestRightPanel(.toggleFullscreen) }
                .keyboardShortcut(shortcuts.combo(for: .rightPanelFullscreen).keyboardShortcut)
        }
    }

    @ViewBuilder
    private var tabShortcutButtons: some View {
        Group {
            ForEach(Array(Self.tabActions.enumerated()), id: \.offset) { idx, action in
                Button("") { sessions.activateTab(atIndex: idx) }
                    .keyboardShortcut(shortcuts.combo(for: action).keyboardShortcut)
            }
            Button("") { sessions.activateAdjacentTab(delta: 1) }
                .keyboardShortcut(shortcuts.combo(for: .nextTab).keyboardShortcut)
            Button("") { sessions.activateAdjacentTab(delta: -1) }
                .keyboardShortcut(shortcuts.combo(for: .prevTab).keyboardShortcut)
            Button("") { sessions.presentAddMachine() }
                .keyboardShortcut(shortcuts.combo(for: .addMachine).keyboardShortcut)
        }
    }

    // 文字缩放（global，global-text-scaling）：⌘=/⌘-/⌘0。
    @ViewBuilder
    private var textScaleButtons: some View {
        Group {
            Button("") { applyTextStep(1) }
                .keyboardShortcut(shortcuts.combo(for: .increaseTextSize).keyboardShortcut)
            Button("") { applyTextStep(-1) }
                .keyboardShortcut(shortcuts.combo(for: .decreaseTextSize).keyboardShortcut)
            Button("") { textScale.reset() }
                .keyboardShortcut(shortcuts.combo(for: .resetTextSize).keyboardShortcut)
        }
    }

    /// U1 分发：先把当前有效档折算为覆盖档基线，再沿阶梯移动一档（钳制两端）。
    private func applyTextStep(_ delta: Int) {
        let base = textScale.baseline(effective: effectiveSize)
        if delta > 0 { textScale.increase(baseline: base) } else { textScale.decrease(baseline: base) }
    }

    private func animate(_ changes: () -> Void) {
        if reduceMotion { changes() }
        else { withAnimation { changes() } }
    }
}
