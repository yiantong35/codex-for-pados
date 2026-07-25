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

/// 主界面（复刻 Codex desktop 五窗口工作区骨架，自绘三栏重构 custom-resizable-columns）：
/// 顶栏用 safeAreaInset(.top)、摘要用常驻 overlay，均挂在自绘三栏容器 ResizableColumns 外层（design D6）。
/// - 左边栏 = ResizableColumns 左列（条件渲染，leftVisible 承接，D5）；右边栏 = 右列（showRight 承接）。
/// - 下边栏 = VStack 底部兄弟槽：横跨左+中+右、把三栏挤压上移（design D2，布局翻转）。
/// - 摘要 = :≡ 按钮触发的常驻悬浮浮层（overlay，design D2），非占列。
struct RootSplitView: View {
    @Environment(ConnectionStore.self) private var connection
    @Environment(ProjectsStore.self) private var projects
    @Environment(EnvironmentInspectorModel.self) private var envInspector
    // 真实系统深浅值：theme=.system 时本视图跟随系统，此值即真实系统外观，传给设置 sheet
    // 以正确解析 .system（规避 sheet .preferredColorScheme(nil) 无法重置强制值）。
    @Environment(\.colorScheme) private var systemColorScheme
    @State private var selectedThreadId: String?

    /// 面板布局状态（设计 D4，方案 A）：从私有 @State 抬升，顶栏按钮 + 面板快捷键共享同一份。
    @State private var layout: WorkspaceLayoutStore
    // 下栏高度（自绘纵向拖 + clamp）。下栏为外层 VStack 底部兄弟槽（design D2）。
    @State private var bottomHeight: CGFloat = WorkspaceMetrics.bottomPanelIdealHeight

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
        // 顶栏与摘要 overlay 迁到自绘三栏容器 resizableColumns 外层（design D6）：顶栏用
        // .safeAreaInset(.top) 挂外层横跨三栏，摘要用常驻 overlay 落在顶栏下方内容区。
        VStack(spacing: 0) {
            resizableColumns
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

            // 下栏：VStack 底部兄弟槽，横跨左+中+右、把 resizableColumns 挤压上移（design D2 目标，改用 VStack 实现）。
            if layout.showBottom {
                Divider()
                BottomPanelView(height: $bottomHeight, cwd: selectedThread?.cwd)
                    // 从底部滑入/滑出，配合顶栏按钮的 withAnimation，弹出不再僵硬（#1）。
                    .transition(.move(edge: .bottom))
            }
        }
        .background { ShortcutLayer(layout: layout) }   // T10：隐藏快捷键层挂稳定独立视图（不随 body 重算重建）
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

            // 新建会话：SidebarView 无导航栏（已移除 NavigationSplitView），故新建入口挂在此自定义顶栏（design D1 深挖）。点击发 thread/start，切 selectedThreadId 进入新会话。
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

    // MARK: - 自绘三栏（custom-resizable-columns，替换 NavigationSplitView + .inspector）

    private var resizableColumns: some View {
        @Bindable var layout = layout
        return ResizableColumns(
            leftWidth: $layout.leftWidth,
            rightWidth: $layout.rightWidth,
            leftVisible: layout.leftVisible,
            rightVisible: layout.showRight,
            onResizeEnded: { saveColumnWidths() }
        ) {
            SidebarView(selectedThreadId: $selectedThreadId)
        } center: {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } right: {
            RightPanelContainerView(cwd: selectedThread?.cwd, mainThreadId: selectedThreadId)
                // 右栏在自绘列内仍显式注入环境（对齐原 .inspector 注入），
                // 否则 RightPanelContainerView 读环境时运行时崩溃。
                .environment(activeConversation)
                .environment(layout)   // 设计 D6：右栏跳转信号载体
        }
    }

    // Task 4 接入 ColumnWidthStore 后替换为真实持久化；本任务先空实现让编译通过。
    private func saveColumnWidths() {}

    @ViewBuilder private var content: some View {
        if let id = selectedThreadId {
            ConversationView(threadId: id).id(id)
        } else {
            Color(.systemBackground)
        }
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

    /// ⌘1..⌘9 对应的动作（下标 i → 机器数组第 i 项）。
    private static let tabActions: [ShortcutAction] =
        [.tab1, .tab2, .tab3, .tab4, .tab5, .tab6, .tab7, .tab8, .tab9]

    var body: some View {
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
}
