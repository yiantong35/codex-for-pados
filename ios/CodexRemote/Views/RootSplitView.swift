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
/// 顶栏用 safeAreaInset(.top)、摘要用常驻 overlay，均挂在自绘三栏容器 ResizableColumns 外层（design D6）。
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

    /// 每次外部载入列宽（切 tab / 冷启动）自增，驱动 ResizableColumns 用真实总宽重新收敛（修复窄屏恢复溢出）。
    @State private var widthLoadRevision = 0
    @State private var fileOpenTask: Task<Void, Never>?
    @State private var operationError: String?
    @State private var selectionReconcileTask: Task<Void, Never>?
    @State private var isReconcilingSelection = false
    @State private var pendingSelectionReconcileIDs: Set<String>?
    @State private var latestSelectionReconcileIDs: Set<String>?
    @State private var showRePairing = false
    @State private var connectionFailureDetails: String?
    @State private var manualReconnectInProgress = false
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
                    if let state = effectiveBannerState {
                        ConnectionBanner(
                            state: state,
                            onReconnect: beginManualReconnect,
                            onShowDetails: { connectionFailureDetails = $0 },
                            onRePair: { showRePairing = true }
                        )
                    }

                    resizableColumns
                    // 摘要：常驻悬浮浮层（design D2 改）。用 overlay 而非 .popover，故点击别处不收回，
                    // 仅由系统工具栏摘要按钮显隐；浮层位于工具栏下方的工作区内容层。
                    .overlay(alignment: .topTrailing) {
                        if layout.showSummary {
                            GeometryReader { geometry in
                                SummaryPopoverView(state: activeConversation.state, thread: selectedThread, env: envInspector,
                                                   onOpenReview: { layout.requestRightPanel(.review) })
                                    .frame(width: min(340, max(0, geometry.size.width - 24)))
                                    .task(id: summaryEnvKey) {
                                        if connection.phase == .ready, let rpc = connection.rpc {
                                            envInspector.attach(rpc: rpc)
                                            await envInspector.refresh(cwd: selectedThread?.cwd)
                                        }
                                    }
                                    .frame(maxHeight: 480)
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
            }
        }
        .toolbar { workspaceToolbar }
        .navigationBarTitleDisplayMode(.inline)
        .background { ShortcutLayer(layout: layout) }   // T10：隐藏快捷键层挂稳定独立视图（不随 body 重算重建）
        .environment(activeConversation)
        .sheet(isPresented: $layout.showSettings) { SettingsPageView(systemColorScheme: systemColorScheme) }
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

    // MARK: - 原生工作区工具栏

    @ToolbarContentBuilder
    private var workspaceToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            TabBarView()
        }

        ToolbarItemGroup(placement: .topBarTrailing) {
            Button(action: createThread) { toolbarImage("plus") }
                .accessibilityLabel(Text("sidebar.newThread"))
                .disabled(projects.isCreatingThread)

            ControlGroup {
                panelToolbarButton(
                    symbol: "rectangle.leadinghalf.inset.filled",
                    label: "workspace.leftPanel.toggle",
                    isOn: layout.leftVisible
                ) {
                    animate { layout.leftVisible.toggle(); layout.lastRequested = .left }
                }
                panelToolbarButton(
                    symbol: "rectangle.bottomthird.inset.filled",
                    label: "workspace.bottomPanel.toggle",
                    isOn: layout.showBottom
                ) {
                    animate { layout.showBottom.toggle() }
                }
                panelToolbarButton(
                    symbol: "list.bullet",
                    label: "workspace.summary.toggle",
                    isOn: layout.showSummary
                ) {
                    animate { layout.showSummary.toggle() }
                }
                panelToolbarButton(
                    symbol: "rectangle.trailinghalf.inset.filled",
                    label: "workspace.rightPanel.toggle",
                    isOn: layout.showRight
                ) {
                    animate { layout.showRight.toggle(); layout.lastRequested = .right }
                }
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            Button { layout.showSettings = true } label: { toolbarImage("gearshape") }
                .accessibilityLabel(Text("settings.accessibility"))
        }
    }

    private func toolbarImage(_ symbol: String, selected: Bool = false) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 21, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }

    private func panelToolbarButton(
        symbol: String,
        label: LocalizedStringKey,
        isOn: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) { toolbarImage(symbol, selected: isOn) }
            .accessibilityLabel(Text(label))
            .accessibilityValue(Text(isOn ? "workspace.panel.shown" : "workspace.panel.hidden"))
            .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func animate(_ changes: () -> Void) {
        if reduceMotion { changes() }
        else { withAnimation { changes() } }
    }

    private func createThread() {
        guard connection.phase == .ready, let rpc = connection.rpc else {
            operationError = L10n.string("operation.unavailable.offline", locale: LocaleManager.currentLocale)
            return
        }
        Task {
            guard let newId = await projects.createThread(rpc: rpc) else {
                if let error = projects.createThreadError { operationError = error }
                return
            }
            workspaceState.selectedThreadId = newId
            projects.markViewed(threadId: newId, updatedAt: Date().timeIntervalSince1970)
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
            loadRevision: widthLoadRevision,
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
        let resolved = columnWidths.resolvedWidths(for: id, total: assumedTotalWidth)
        layout.leftWidth = resolved.left
        layout.rightWidth = resolved.right
        // 载入后自增修订号：驱动 ResizableColumns 用真实总宽再收敛（窄屏冷启动/切 tab 恢复防溢出）。
        widthLoadRevision &+= 1
    }

    /// 读回时的保守总宽估计（iPad 11" 横屏宽）；真实几何由 ResizableColumns 的 onChange(of:total, initial:true) 在首帧即重 clamp 纠正。
    private var assumedTotalWidth: CGFloat { 1_194 }

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
            activeConversation.state = nil
            activeConversation.contextIdentity = nil
            activeConversation.fetchFullDiff = nil
            activeConversation.startReview = nil
            activeConversation.applyThreadSnapshot = nil
            activeConversation.fetchGeneration &+= 1
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

    var body: some View {
        bannerContent
        .font(.subheadline)
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(.thinMaterial)
        .overlay(alignment: .bottom) { Divider() }
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
        case .trustRevoked:
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    statusLabel("connection.trustRevoked")
                    Spacer(minLength: 4)
                    rePairButton
                }
                VStack(alignment: .leading, spacing: 0) {
                    statusLabel("connection.trustRevoked")
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

            // 右栏跳转 / 全屏（workspace）——requestRightPanel 先开右栏再发信号
            Button("") { layout.requestRightPanel(.review) }
                .keyboardShortcut(shortcuts.combo(for: .rightPanelReview).keyboardShortcut)
            Button("") { layout.requestRightPanel(.files) }
                .keyboardShortcut(shortcuts.combo(for: .rightPanelFiles).keyboardShortcut)
            Button("") { layout.requestRightPanel(.sideChat) }
                .keyboardShortcut(shortcuts.combo(for: .rightPanelSideChat).keyboardShortcut)
            Button("") { layout.requestRightPanel(.toggleFullscreen) }
                .keyboardShortcut(shortcuts.combo(for: .rightPanelFullscreen).keyboardShortcut)

            // Tab（global）——拆子 Group，规避 ViewBuilder 单层 10 子视图上限
            tabShortcutButtons
        }
        // 投递安全的「隐形但仍注册」组合（替代 .hidden()）：
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
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

    private func animate(_ changes: () -> Void) {
        if reduceMotion { changes() }
        else { withAnimation { changes() } }
    }
}
