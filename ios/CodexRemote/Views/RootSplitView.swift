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
/// detail 区 = VStack { 上半 HStack(中间对话 + 右栏自绘可拖列) ; 下栏(条件) }，
/// 故下栏只压短「中间 + 右栏」、不伸到左边栏（design D4 / 布局层级）。
/// 摘要为 :≡ 按钮触发的常驻悬浮浮层（overlay，design D2 改），非占列。
struct RootSplitView: View {
    @Environment(ConnectionStore.self) private var connection
    @Environment(ProjectsStore.self) private var projects
    @State private var selectedThreadId: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    // 五窗口 toggle 状态（design D5：每个面板一个 @State Bool）。
    @State private var showRightPanel: Bool
    @State private var showBottomPanel: Bool
    @State private var showSummary = false

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
                // 左栏可拖提示：系统列拖动本就可用，这里只在右缘画常驻装饰把手作视觉提示；
                // allowsHitTesting(false) 不拦截系统拖动，保持左栏原本顺滑的 resize。
                .overlay(alignment: .trailing) {
                    Capsule().fill(Color.secondary.opacity(0.55))
                        .frame(width: 3, height: 44)
                        .padding(.trailing, 2)
                        .allowsHitTesting(false)
                }
        } detail: {
            detail
                .toolbar(removing: .sidebarToggle)
        }
        .navigationSplitViewStyle(.balanced)
    }

    // detail = WorkspaceDetailRegion（中间对话 + 右栏自绘可拖列 + 下栏），见下方独立视图。
    // 关键：右栏/下栏的尺寸 @State 放在 WorkspaceDetailRegion 内部，拖动时只重渲染该子树，
    // 不冒泡到 RootSplitView.body → NavigationSplitView 不被反复重建 → 实时重绘且不闪（#5）。
    private var detail: some View {
        WorkspaceDetailRegion(showRightPanel: showRightPanel, showBottomPanel: showBottomPanel) {
            content
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

/// detail 区（中栏对话 + 右栏自绘可拖列 + 下栏）。
/// 把右栏宽/下栏高的 @State 关在这里：拖动只重渲染本视图，不触碰外层 NavigationSplitView，
/// 实现「实时重绘但不闪」（左栏系统列本就如此，右栏此前因状态在 RootSplitView 导致整树重渲染才闪）。
private struct WorkspaceDetailRegion<Content: View>: View {
    let showRightPanel: Bool
    let showBottomPanel: Bool
    @ViewBuilder var content: Content

    @State private var rightWidth: CGFloat = WorkspaceMetrics.rightPanelIdealWidth
    @State private var rightDragBase: CGFloat?
    @State private var bottomHeight: CGFloat = WorkspaceMetrics.bottomPanelIdealHeight

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if showRightPanel {
                    // 实时重绘：拖动中直接改 rightWidth（手势起点锁基准宽避免累计加速）；
                    // 状态隔离在本视图内 → 不闪，无需预览导引线（#3 去掉橙实线）。
                    PanelResizeHandle(
                        onChanged: { tx in
                            if rightDragBase == nil { rightDragBase = rightWidth }
                            rightWidth = WorkspaceMetrics.resizedRightWidth(
                                current: rightDragBase ?? rightWidth, dragX: tx)
                        },
                        onEnded: { rightDragBase = nil }
                    )
                    RightPanelView()
                        .frame(width: rightWidth)
                        .frame(maxHeight: .infinity)
                        .transition(.move(edge: .trailing))
                }
            }
            if showBottomPanel {
                Divider()
                BottomPanelView(height: $bottomHeight)
            }
        }
    }
}
