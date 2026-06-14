import SwiftUI
import Observation

/// 当前活跃会话状态的共享持有者：ConversationView 写入最新 state，
/// 顶栏摘要 popover 读出用于派生 diff/plan/tasks（cwd 仍取选中 ThreadSummary）。
@Observable
@MainActor
final class ActiveConversationHolder {
    var state: ConversationState?
}

/// 主界面（复刻 Codex desktop 五窗口工作区骨架，三列系统列重构 workspace-3col-layout）：
/// 顶/底栏均用 safeAreaInset 挂在 split 外层（不用 VStack 包裹 split，避免破坏系统列/inspector 拖动）。
/// - 左边栏 = NavigationSplitView 系统 sidebar 列；右边栏 = 中栏 `.inspector`（右侧系统列，系统托管 resize 不闪）。
/// - 下边栏 = split 外层全宽 `.safeAreaInset(edge:.bottom)`：横跨左+中+右、压所有（design D2，布局翻转）。
/// - 摘要 = :≡ 按钮触发的常驻悬浮浮层（overlay，design D2），非占列。
struct RootSplitView: View {
    @Environment(ConnectionStore.self) private var connection
    @Environment(ProjectsStore.self) private var projects
    @State private var selectedThreadId: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    // 五窗口 toggle 状态（design D5：每个面板一个 @State Bool）。
    @State private var showRightPanel: Bool
    @State private var showBottomPanel: Bool
    @State private var showSummary = false
    // 下栏高度（自绘纵向拖 + clamp）。下栏挂在 split 外层全宽 safeAreaInset（design D2）。
    @State private var bottomHeight: CGFloat = WorkspaceMetrics.bottomPanelIdealHeight
    // 左栏把手拖动高亮：系统列钩不到拖动事件，改为监听左栏宽度变化——拖系统分隔线时宽度持续变，
    // 据此把左把手点亮成橙，停止 250ms 后复原（不拦截手势、不换架构）。
    @State private var leftHandleActive = false
    @State private var leftResizeReset: Task<Void, Never>?
    // 右栏(inspector)同理：系统检视列的拖动分隔线很隐蔽，叠装饰把手 + 监听 inspector 宽度变化点亮。
    @State private var rightHandleActive = false
    @State private var rightResizeReset: Task<Void, Never>?

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

    var body: some View {
        split
            // 摘要：常驻悬浮浮层（design D2 改）。用 overlay 而非 .popover，故点击别处不收回，
            // 仅由顶栏摘要按钮显隐。overlay 放在 safeAreaInset 之前 → 浮层落在顶栏「下方」内容区，
            // 不会遮挡顶栏按钮（否则会盖住摘要按钮本身导致收不回）。
            .overlay(alignment: .topTrailing) {
                if showSummary {
                    SummaryPopoverView(state: activeConversation.state, thread: selectedThread)
                        .frame(width: 340)
                        .frame(maxHeight: 480)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
                        .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
                        .padding(.top, 8)
                        .padding(.trailing, 12)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            // 下栏：全宽外层 safeAreaInset，横跨左+中+右、把 split 整体上推（design D2，压所有）。
            // 与顶栏 safeAreaInset 对称；不 VStack 包裹 split → 不破坏系统列/inspector 拖动。
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if showBottomPanel {
                    VStack(spacing: 0) {
                        Divider()
                        BottomPanelView(height: $bottomHeight)
                    }
                    // 从底部滑入/滑出，配合顶栏按钮的 withAnimation，弹出不再僵硬（#1）。
                    .transition(.move(edge: .bottom))
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    topBar
                    Divider()
                }
            }
            .environment(activeConversation)
    }

    // MARK: - 顶部固定全局工具栏：左面板 · 下面板 · 右面板 · 摘要(:≡) · 设置

    private var topBar: some View {
        // 全部按钮靠右；顺序：左面板 · 下面板 · 摘要 · 右面板 · 设置。
        // 三个面板图标用统一的 inset.filled 矩形族（一致风格，不混描边/填充）；
        // 摘要用 list.bullet(:≡ 两圆点两横线)；图标走主题色(.tint)、随系统深浅适配。
        HStack(spacing: 18) {
            Spacer()

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

            // 设置。
            SettingsMenu()
        }
        .font(.title3)
        // 图标用 .primary（标签色，随深浅自动适配黑/白），不用 iOS 默认蓝。
        .tint(Color.primary)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - split：左栏满高 | detail 区(VStack)

    private var split: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selectedThreadId: $selectedThreadId)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
                .toolbar(removing: .sidebarToggle)
                .toolbarBackground(.hidden, for: .navigationBar)
                // 监听左栏宽度变化 → 拖系统分隔线时点亮把手（见 leftHandleActive 说明）。
                .background {
                    GeometryReader { proxy in
                        Color.clear.onChange(of: proxy.size.width) { _, _ in
                            leftHandleActive = true
                            leftResizeReset?.cancel()
                            leftResizeReset = Task {
                                try? await Task.sleep(for: .milliseconds(250))
                                if !Task.isCancelled { leftHandleActive = false }
                            }
                        }
                    }
                }
                // 左栏可拖提示：右缘常驻装饰把手；拖动中（宽度在变）变橙加粗。
                // allowsHitTesting(false) 不拦截系统拖动，保持左栏原本顺滑的 resize。
                .overlay(alignment: .trailing) {
                    Capsule()
                        .fill(leftHandleActive ? Color.accentColor : Color.secondary.opacity(0.55))
                        .frame(width: leftHandleActive ? 5 : 3, height: 44)
                        .padding(.trailing, 2)
                        .allowsHitTesting(false)
                        .animation(.easeOut(duration: 0.12), value: leftHandleActive)
                }
        } detail: {
            detail
                .toolbar(removing: .sidebarToggle)
        }
        .navigationSplitViewStyle(.balanced)
    }

    // detail = 中栏对话 + 右栏 `.inspector`（右侧系统检视列，系统托管 resize 不闪，design D1）。
    // 不被任何 VStack 包裹（下栏已移到 body 外层 safeAreaInset）→ inspector 拖动无 VStack 干扰（design D3）。
    private var detail: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .inspector(isPresented: $showRightPanel) {
                RightPanelView()
                    // 左缘装饰把手（可拖提示）：系统检视列的拖动分隔线隐蔽，这里叠一条常驻把手；
                    // 监听 inspector 宽度变化 → 拖动中点亮成橙。allowsHitTesting(false) 不拦截系统拖动。
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(rightHandleActive ? Color.accentColor : Color.secondary.opacity(0.55))
                            .frame(width: rightHandleActive ? 5 : 3, height: 44)
                            .padding(.leading, 2)
                            .allowsHitTesting(false)
                            .animation(.easeOut(duration: 0.12), value: rightHandleActive)
                    }
                    .background {
                        GeometryReader { proxy in
                            Color.clear.onChange(of: proxy.size.width) { _, _ in
                                rightHandleActive = true
                                rightResizeReset?.cancel()
                                rightResizeReset = Task {
                                    try? await Task.sleep(for: .milliseconds(250))
                                    if !Task.isCancelled { rightHandleActive = false }
                                }
                            }
                        }
                    }
                    .inspectorColumnWidth(min: WorkspaceMetrics.rightPanelMinWidth,
                                          ideal: WorkspaceMetrics.rightPanelIdealWidth,
                                          max: WorkspaceMetrics.rightPanelMaxWidth)
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
