import SwiftUI
import Observation

/// 当前活跃会话状态的共享持有者：ConversationView 写入最新 state，
/// 顶栏摘要 popover 读出用于派生 diff/plan/tasks（cwd 仍取选中 ThreadSummary）。
@Observable
@MainActor
final class ActiveConversationHolder {
    var state: ConversationState?
    /// 进度卡片点「X 文件」请求打开右栏的信号（一次性，RootSplitView 消费后复位）。
    var requestRightPanel: Bool = false
    /// 拉取远端全量 diff 的回调（由持有 ConversationStore 的 ConversationView 注入）。
    /// 审查面板切到「全量」时调用；未接线（nil）时返回 nil，面板降级空态。
    var fetchFullDiff: ((_ cwd: String) async -> String?)?
    /// 发起 AI 审查的回调（由持有 ConversationStore 的 ConversationView 注入，设计 D4）。
    /// 审查 tab 的「本轮/全量」发起入口调用；未接线（nil）→ 入口禁用。返回是否成功发出。
    var startReview: ((_ mode: ReviewSourceMode) async -> Bool)?
}

/// 主界面（复刻 Codex desktop 五窗口工作区骨架，三列系统列重构 workspace-3col-layout）：
/// 顶/底栏均用 safeAreaInset 挂在 split 外层（不用 VStack 包裹 split，避免破坏系统列/inspector 拖动）。
/// - 左边栏 = NavigationSplitView 系统 sidebar 列；右边栏 = 中栏 `.inspector`（右侧系统列，系统托管 resize 不闪）。
/// - 下边栏 = split 外层全宽 `.safeAreaInset(edge:.bottom)`：横跨左+中+右、压所有（design D2，布局翻转）。
/// - 摘要 = :≡ 按钮触发的常驻悬浮浮层（overlay，design D2），非占列。
struct RootSplitView: View {
    @Environment(ConnectionStore.self) private var connection
    @Environment(ProjectsStore.self) private var projects
    @Environment(EnvironmentInspectorModel.self) private var envInspector
    @Environment(SessionsManager.self) private var sessions
    @Environment(ShortcutStore.self) private var shortcuts
    // 真实系统深浅值：theme=.system 时本视图跟随系统，此值即真实系统外观，传给设置 sheet
    // 以正确解析 .system（规避 sheet .preferredColorScheme(nil) 无法重置强制值）。
    @Environment(\.colorScheme) private var systemColorScheme
    @State private var selectedThreadId: String?

    /// 面板布局状态（设计 D4，方案 A）：从私有 @State 抬升，顶栏按钮 + 面板快捷键共享同一份。
    @State private var layout: WorkspaceLayoutStore
    // 下栏高度（自绘纵向拖 + clamp）。下栏挂在 split 外层全宽 safeAreaInset（design D2）。
    @State private var bottomHeight: CGFloat = WorkspaceMetrics.bottomPanelIdealHeight
    // 左栏把手拖动高亮：系统列钩不到拖动事件，改为监听真实分隔线坐标变化——拖系统分隔线时坐标持续变，
    // 据此把左把手点亮成橙，停止 250ms 后复原（不拦截手势、不换架构）。
    @State private var leftHandleActive = false
    @State private var leftResizeReset: Task<Void, Never>?
    // 右栏(inspector)同理：系统检视列的拖动分隔线很隐蔽，叠装饰把手 + 监听真实分隔线坐标变化点亮。
    @State private var rightHandleActive = false
    @State private var rightResizeReset: Task<Void, Never>?
    private let splitCoordinateSpaceName = "RootSplitView.split"
    @State private var leftDividerX: CGFloat = 300
    @State private var rightDividerX: CGFloat?
    @State private var hasMeasuredLeftDivider = false
    @State private var hasMeasuredRightDivider = false
    @State private var columnResizeHandlePinnedCenterY: CGFloat?

    /// 当前活跃会话 state 的共享持有者：ConversationView 写入、摘要 popover 读出。
    @State private var activeConversation = ActiveConversationHolder()

    /// 便利初始化：允许注入面板初始展开态（供快照测试覆盖全开布局）。
    init(initialRightOpen: Bool = false, initialBottomOpen: Bool = false) {
        _layout = State(initialValue: WorkspaceLayoutStore(showRight: initialRightOpen,
                                                           showBottom: initialBottomOpen))
    }

    private var selectedThread: ThreadSummary? {
        guard let id = selectedThreadId else { return nil }
        return projects.allThreadsSorted.first { $0.id == id }
    }

    // 批次⑤：摘要打开/切换会话/连接就绪时触发环境信息刷新的 key（含连接态避免冷启动漏刷 I2）。
    private var summaryEnvKey: String { "\(layout.showSummary)-\(selectedThreadId ?? "")-\(connection.phase == .ready)" }

    var body: some View {
        @Bindable var layout = layout
        // 下栏改为 VStack 兄弟槽（不再用 split 的 .safeAreaInset(.bottom)）：
        // 根因——safeAreaInset(.bottom) 挂在 NavigationSplitView 上时，其系统列(sidebar/detail)
        // 以 maxHeight:.infinity 填满、不吃底部 inset，导致下栏覆盖而非上推挤压（Task 6 诊断实测：
        // 展开前后 detail 全局 frame 完全一致 maxY=1190）。放进 VStack 让下栏占真实布局槽 → split 被挤压。
        // 顶栏仍用 split 自身的 safeAreaInset(.top)（该方向系统列正常响应），摘要 overlay 也仍挂 split。
        VStack(spacing: 0) {
            split
                // 摘要：常驻悬浮浮层（design D2 改）。用 overlay 而非 .popover，故点击别处不收回，
                // 仅由顶栏摘要按钮显隐。overlay 放在 safeAreaInset 之前 → 浮层落在顶栏「下方」内容区，
                // 不会遮挡顶栏按钮（否则会盖住摘要按钮本身导致收不回）。
                .overlay(alignment: .topTrailing) {
                    if layout.showSummary {
                        SummaryPopoverView(state: activeConversation.state, thread: selectedThread, env: envInspector)
                            .frame(width: 340)
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
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        topBar
                        Divider()
                    }
                }

            // 下栏：VStack 底部兄弟槽，横跨左+中+右、把 split 挤压上移（design D2 目标，改用 VStack 实现）。
            if layout.showBottom {
                Divider()
                BottomPanelView(height: $bottomHeight, cwd: selectedThread?.cwd)
                    // 从底部滑入/滑出，配合顶栏按钮的 withAnimation，弹出不再僵硬（#1）。
                    .transition(.move(edge: .bottom))
            }
        }
        .background { shortcutLayer(layout) }   // T10：隐藏快捷键层挂稳定视图
        .onChange(of: activeConversation.requestRightPanel) { _, req in
            if req {
                withAnimation { layout.showRight = true }
                activeConversation.requestRightPanel = false
            }
        }
        .environment(activeConversation)
        .sheet(isPresented: $layout.showSettings) { SettingsPageView(systemColorScheme: systemColorScheme) }
    }

    // MARK: - 顶部固定全局工具栏：左面板 · 下面板 · 右面板 · 摘要(:≡) · 设置

    private var topBar: some View {
        // 全部按钮靠右；顺序：左面板 · 下面板 · 摘要 · 右面板 · 设置。
        // 三个面板图标用统一的 inset.filled 矩形族（一致风格，不混描边/填充）；
        // 摘要用 list.bullet(:≡ 两圆点两横线)；图标走主题色(.tint)、随系统深浅适配。
        HStack(spacing: 18) {
            Spacer()

            // 新建会话：SidebarView 的系统 .toolbar 按钮在「split + 自定义顶栏 safeAreaInset」布局下不渲染，
            // 故新建入口挂在此自定义顶栏（design D1 深挖）。点击发 thread/start，切 selectedThreadId 进入新会话。
            // rpc 从 connection 显式取（projects.self.rpc 未经 attach 注入，对齐 loadFromServer(rpc:) 模式）。
            Button {
                guard let rpc = connection.rpc else { return }
                Task {
                    guard let newId = await projects.createThread(rpc: rpc) else { return }
                    selectedThreadId = newId
                    projects.markViewed(threadId: newId, updatedAt: Date().timeIntervalSince1970)
                }
            } label: { Image(systemName: "square.and.pencil") }
            .accessibilityLabel(Text("sidebar.newThread"))
            .disabled(projects.isCreatingThread)   // 防抖：创建进行中禁用，避免连点建多个会话

            // 左面板：显式控制 columnVisibility（不叠加系统 sidebarToggle）。
            Button {
                withAnimation { layout.leftVisible.toggle() }
            } label: { Image(systemName: "rectangle.leadinghalf.inset.filled") }
            .accessibilityLabel(Text("workspace.leftPanel.toggle"))

            // 下面板。
            Button { withAnimation { layout.showBottom.toggle() } } label: {
                Image(systemName: "rectangle.bottomthird.inset.filled")
            }
            .accessibilityLabel(Text("workspace.bottomPanel.toggle"))

            // 摘要(:≡ = list.bullet)：常驻悬浮浮层由 body 的 overlay 渲染。
            Button { withAnimation { layout.showSummary.toggle() } } label: {
                Image(systemName: "list.bullet")
            }
            .accessibilityLabel(Text("workspace.summary.toggle"))

            // 右面板。
            Button { withAnimation { layout.showRight.toggle() } } label: {
                Image(systemName: "rectangle.trailinghalf.inset.filled")
            }
            .accessibilityLabel(Text("workspace.rightPanel.toggle"))

            // 设置：gear 直接打开设置页 .sheet（移除旧 popover，设计 D3）。
            Button { layout.showSettings = true } label: {
                Image(systemName: "gearshape")
                    .accessibilityLabel(Text("settings.accessibility"))
            }
        }
        .font(.title3)
        // 图标用 .primary（标签色，随深浅自动适配黑/白），不用 iOS 默认蓝。
        .tint(Color.primary)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - split：左栏 | detail + inspector

    /// columnVisibility ↔ layout.leftVisible 双向派生（设计 D4：columnVisibility 由 leftVisible 派生，
    /// 同时把系统拖动收起列同步回 store）。
    private var columnVisibilityBinding: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { layout.leftVisible ? .all : .detailOnly },
            set: { layout.leftVisible = ($0 != .detailOnly) }
        )
    }

    private var split: some View {
        NavigationSplitView(columnVisibility: columnVisibilityBinding) {
            SidebarView(selectedThreadId: $selectedThreadId)
                .background {
                    GeometryReader { proxy in
                        let dividerX = proxy.frame(in: .named(splitCoordinateSpaceName)).maxX
                        Color.clear
                            .onAppear {
                                updateLeftDividerX(dividerX)
                            }
                            .onChange(of: dividerX) { _, newDividerX in
                                updateLeftDividerX(newDividerX)
                            }
                    }
                }
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
                .toolbar(removing: .sidebarToggle)
                .toolbarBackground(.hidden, for: .navigationBar)
        } detail: {
            detail
                .toolbar(removing: .sidebarToggle)
        }
        .navigationSplitViewStyle(.balanced)
        .coordinateSpace(name: splitCoordinateSpaceName)
        .overlay {
            columnResizeHandles
                .allowsHitTesting(false)
        }
    }

    // detail = 中栏对话 + 右栏 `.inspector`（右侧系统检视列，系统托管 resize 不闪，design D1）。
    // 不被任何 VStack 包裹（下栏已移到 body 外层 safeAreaInset）→ inspector 拖动无 VStack 干扰（design D3）。
    private var detail: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .inspector(isPresented: $layout.showRight) {
                RightPanelContainerView(cwd: selectedThread?.cwd, mainThreadId: selectedThreadId)
                    // inspector 内容在独立系统列，不保证继承 body 链上的 .environment，
                    // 故在此显式注入 ActiveConversationHolder（否则 RightPanelContainerView 读环境时运行时崩溃）。
                    .environment(activeConversation)
                    .environment(layout)   // 设计 D6：右栏跳转信号载体（此处先注入，Task 10 才消费）
                    // 监听 inspector 分隔线坐标变化 → 拖动中点亮统一 overlay 中的右把手。
                    .background {
                        GeometryReader { proxy in
                            let dividerX = proxy.frame(in: .named(splitCoordinateSpaceName)).minX
                            Color.clear
                                .onAppear {
                                    updateRightDividerX(dividerX)
                                }
                                .onChange(of: dividerX) { _, newDividerX in
                                    updateRightDividerX(newDividerX)
                                }
                        }
                    }
                    .inspectorColumnWidth(min: WorkspaceMetrics.rightPanelMinWidth,
                                          ideal: WorkspaceMetrics.rightPanelIdealWidth,
                                          max: WorkspaceMetrics.rightPanelMaxWidth)
            }
    }

    private var columnResizeHandles: some View {
        GeometryReader { proxy in
            let currentCenterY = WorkspaceMetrics.columnResizeHandleCenterY(in: proxy.size.height)
            let centerY = WorkspaceMetrics.columnResizeHandleCenterY(in: proxy.size.height,
                                                                      pinnedCenterY: columnResizeHandlePinnedCenterY)
            let leftWidth = leftHandleActive
                ? WorkspaceMetrics.columnResizeHandleActiveWidth
                : WorkspaceMetrics.columnResizeHandleInactiveWidth
            let rightWidth = rightHandleActive
                ? WorkspaceMetrics.columnResizeHandleActiveWidth
                : WorkspaceMetrics.columnResizeHandleInactiveWidth
            let currentRightDividerX = rightDividerX ?? proxy.size.width - WorkspaceMetrics.rightPanelIdealWidth

            ZStack(alignment: .topLeading) {
                if layout.leftVisible {
                    resizeHandle(active: leftHandleActive, width: leftWidth)
                        .position(x: WorkspaceMetrics.leftColumnResizeHandleCenterX(dividerX: leftDividerX,
                                                                                     handleWidth: leftWidth),
                                  y: centerY)
                }

                if layout.showRight {
                    resizeHandle(active: rightHandleActive, width: rightWidth)
                        .position(x: WorkspaceMetrics.rightColumnResizeHandleCenterX(dividerX: currentRightDividerX,
                                                                                      handleWidth: rightWidth),
                                  y: centerY)
                }
            }
            .animation(.easeOut(duration: 0.12), value: leftHandleActive)
            .animation(.easeOut(duration: 0.12), value: rightHandleActive)
            .onAppear {
                if columnResizeHandlePinnedCenterY == nil {
                    columnResizeHandlePinnedCenterY = currentCenterY
                }
            }
        }
    }

    private func resizeHandle(active: Bool, width: CGFloat) -> some View {
        Capsule()
            .fill(active ? Color.accentColor : Color.secondary.opacity(0.55))
            .frame(width: width, height: WorkspaceMetrics.columnResizeHandleHeight)
    }

    private func updateLeftDividerX(_ newDividerX: CGFloat) {
        guard newDividerX > 0 else { return }
        let changed = hasMeasuredLeftDivider && abs(leftDividerX - newDividerX) > 0.5
        leftDividerX = newDividerX
        hasMeasuredLeftDivider = true

        if changed {
            leftHandleActive = true
            leftResizeReset?.cancel()
            leftResizeReset = Task {
                try? await Task.sleep(for: .milliseconds(250))
                if !Task.isCancelled { leftHandleActive = false }
            }
        }
    }

    private func updateRightDividerX(_ newDividerX: CGFloat) {
        guard newDividerX > 0 else { return }
        let previousDividerX = rightDividerX ?? newDividerX
        let changed = hasMeasuredRightDivider && abs(previousDividerX - newDividerX) > 0.5
        rightDividerX = newDividerX
        hasMeasuredRightDivider = true

        if changed {
            rightHandleActive = true
            rightResizeReset?.cancel()
            rightResizeReset = Task {
                try? await Task.sleep(for: .milliseconds(250))
                if !Task.isCancelled { rightHandleActive = false }
            }
        }
    }

    @ViewBuilder private var content: some View {
        if let id = selectedThreadId {
            ConversationView(threadId: id).id(id)
        } else {
            Color(.systemBackground)
        }
    }

    // MARK: - 隐藏快捷键层（T10）

    /// ⌘1..⌘9 对应的动作（下标 i → 机器数组第 i 项）。
    private static let tabActions: [ShortcutAction] =
        [.tab1, .tab2, .tab3, .tab4, .tab5, .tab6, .tab7, .tab8, .tab9]

    /// 隐藏快捷键层（设计 D5 + 功耗 1-3）：挂稳定视图，每动作一个隐藏 Button +
    /// `.keyboardShortcut(shortcuts.combo(for:).keyboardShortcut)`。隐藏按钮仍注册进
    /// 响应链 → 外接键盘可触发；`shortcuts` 变化 → body 重算 → 快捷键动态刷新（无需 UIKeyCommand）。
    @ViewBuilder
    private func shortcutLayer(_ layout: WorkspaceLayoutStore) -> some View {
        Group {
            // 面板（workspace）
            Button("") { withAnimation { layout.leftVisible.toggle() } }
                .keyboardShortcut(shortcuts.combo(for: .toggleLeftPanel).keyboardShortcut)
            Button("") { withAnimation { layout.showRight.toggle() } }
                .keyboardShortcut(shortcuts.combo(for: .toggleRightPanel).keyboardShortcut)
            Button("") { withAnimation { layout.showBottom.toggle() } }
                .keyboardShortcut(shortcuts.combo(for: .toggleBottomPanel).keyboardShortcut)
            Button("") { withAnimation { layout.showSummary.toggle() } }
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
        .hidden()
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
}
