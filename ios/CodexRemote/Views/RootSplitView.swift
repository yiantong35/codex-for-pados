import SwiftUI
import Observation

/// 当前活跃会话状态的共享持有者：ConversationView 写入最新 state，
/// 顶栏摘要 popover 读出用于派生 diff/plan/tasks（cwd 仍取选中 ThreadSummary）。
@Observable
@MainActor
final class ActiveConversationHolder {
    var state: ConversationState?
}

/// 主界面（复刻 Codex desktop 五窗口工作区骨架）：
/// 顶部固定全局工具栏（safeAreaInset，不用 VStack 包整个 split，避免破坏 inspector 拖动）
/// + NavigationSplitView：左边栏(满高) | detail 区。
/// detail 区 = VStack { 上半(中间对话 + 右栏 .inspector) ; 下栏(条件) }，
/// 故下栏只压短「中间 + 右栏」、不伸到左边栏（design D4 / 布局层级）。
/// 摘要为 :≡ 按钮触发的 .popover（design D2），非占列。
struct RootSplitView: View {
    @Environment(ConnectionStore.self) private var connection
    @Environment(ProjectsStore.self) private var projects
    @State private var selectedThreadId: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    // 五窗口 toggle 状态（design D5：每个面板一个 @State Bool）。
    @State private var showRightPanel: Bool
    @State private var showBottomPanel: Bool
    @State private var showSummary = false
    @State private var bottomHeight: CGFloat = WorkspaceMetrics.bottomPanelIdealHeight

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
        HStack(spacing: 18) {
            // 左面板：显式控制 columnVisibility（不叠加系统 sidebarToggle）。
            Button {
                withAnimation {
                    columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
                }
            } label: { Image(systemName: "sidebar.leading") }
            .accessibilityLabel(Text("workspace.leftPanel.toggle"))

            // 下面板。
            Button { withAnimation { showBottomPanel.toggle() } } label: {
                Image(systemName: "rectangle.bottomthird.inset.filled")
            }
            .accessibilityLabel(Text("workspace.bottomPanel.toggle"))

            // 右面板。
            Button { withAnimation { showRightPanel.toggle() } } label: {
                Image(systemName: "sidebar.right")
            }
            .accessibilityLabel(Text("workspace.rightPanel.toggle"))

            // 摘要(:≡)：Codex 真实 panel-right SVG（关=描边 / 开=填充）。.popover 挂在此按钮。
            Button { showSummary.toggle() } label: {
                Image(showSummary ? "InspectorOpen" : "InspectorClosed")
                    .renderingMode(.template).resizable().scaledToFit()
                    .frame(width: 22, height: 22)
            }
            .accessibilityLabel(Text("workspace.summary.toggle"))
            .popover(isPresented: $showSummary) {
                SummaryPopoverView(state: activeConversation.state, thread: selectedThread)
            }

            Spacer()

            SettingsMenu()
        }
        .font(.title3)
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
        } detail: {
            detail
                .toolbar(removing: .sidebarToggle)
        }
        .navigationSplitViewStyle(.balanced)
    }

    // detail = 上半(content + 右栏 inspector) + 下栏(条件)。下栏在此 VStack 内 → 不压左栏。
    private var detail: some View {
        VStack(spacing: 0) {
            content
                .inspector(isPresented: $showRightPanel) {
                    RightPanelView()
                        .inspectorColumnWidth(min: WorkspaceMetrics.rightPanelMinWidth,
                                              ideal: WorkspaceMetrics.rightPanelIdealWidth,
                                              max: WorkspaceMetrics.rightPanelMaxWidth)
                }
            if showBottomPanel {
                Divider()
                BottomPanelView(height: $bottomHeight)
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
