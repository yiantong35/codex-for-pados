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
    // 真实系统深浅值：theme=.system 时本视图跟随系统，此值即真实系统外观，传给设置 sheet
    // 以正确解析 .system（规避 sheet .preferredColorScheme(nil) 无法重置强制值）。
    @Environment(\.colorScheme) private var systemColorScheme
    @State private var selectedThreadId: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    // 五窗口 toggle 状态（design D5：每个面板一个 @State Bool）。
    @State private var showRightPanel: Bool
    @State private var showBottomPanel: Bool
    @State private var showSummary = false
    @State private var showSettings = false
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
        _showRightPanel = State(initialValue: initialRightOpen)
        _showBottomPanel = State(initialValue: initialBottomOpen)
    }

    private var selectedThread: ThreadSummary? {
        guard let id = selectedThreadId else { return nil }
        return projects.allThreadsSorted.first { $0.id == id }
    }

    // 批次⑤：摘要打开/切换会话/连接就绪时触发环境信息刷新的 key（含连接态避免冷启动漏刷 I2）。
    private var summaryEnvKey: String { "\(showSummary)-\(selectedThreadId ?? "")-\(connection.phase == .ready)" }

    var body: some View {
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
                    if showSummary {
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
            if showBottomPanel {
                Divider()
                BottomPanelView(height: $bottomHeight, cwd: selectedThread?.cwd)
                    // 从底部滑入/滑出，配合顶栏按钮的 withAnimation，弹出不再僵硬（#1）。
                    .transition(.move(edge: .bottom))
            }
        }
        .onChange(of: activeConversation.requestRightPanel) { _, req in
            if req {
                withAnimation { showRightPanel = true }
                activeConversation.requestRightPanel = false
            }
        }
        .environment(activeConversation)
        .sheet(isPresented: $showSettings) { SettingsPageView(systemColorScheme: systemColorScheme) }
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
                withAnimation {
                    columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
                }
            } label: { Image(systemName: "rectangle.leadinghalf.inset.filled") }
            .accessibilityLabel(Text("workspace.leftPanel.toggle"))

            // 下面板。
            Button { withAnimation { showBottomPanel.toggle() } } label: {
                Image(systemName: "rectangle.bottomthird.inset.filled")
            }
            .accessibilityLabel(Text("workspace.bottomPanel.toggle"))

            // 摘要(:≡ = list.bullet)：常驻悬浮浮层由 body 的 overlay 渲染。
            Button { withAnimation { showSummary.toggle() } } label: {
                Image(systemName: "list.bullet")
            }
            .accessibilityLabel(Text("workspace.summary.toggle"))

            // 右面板。
            Button { withAnimation { showRightPanel.toggle() } } label: {
                Image(systemName: "rectangle.trailinghalf.inset.filled")
            }
            .accessibilityLabel(Text("workspace.rightPanel.toggle"))

            // 设置：gear 直接打开设置页 .sheet（移除旧 popover，设计 D3）。
            Button { showSettings.toggle() } label: {
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

    private var split: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
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
            .inspector(isPresented: $showRightPanel) {
                RightPanelContainerView(cwd: selectedThread?.cwd, mainThreadId: selectedThreadId)
                    // inspector 内容在独立系统列，不保证继承 body 链上的 .environment，
                    // 故在此显式注入 ActiveConversationHolder（否则 RightPanelContainerView 读环境时运行时崩溃）。
                    .environment(activeConversation)
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
                if columnVisibility != .detailOnly {
                    resizeHandle(active: leftHandleActive, width: leftWidth)
                        .position(x: WorkspaceMetrics.leftColumnResizeHandleCenterX(dividerX: leftDividerX,
                                                                                     handleWidth: leftWidth),
                                  y: centerY)
                }

                if showRightPanel {
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
}
