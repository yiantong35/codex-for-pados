import SwiftUI

/// 右栏 tab 标识（D1）。三个 tab：审查 / 文件 / 侧聊。
enum RightPanelTab: CaseIterable, Identifiable {
    case review, files, sideChat
    var id: Self { self }
    var label: String {
        switch self {
        case .review:   return "审查"
        case .files:    return "文件"
        case .sideChat: return "侧聊"
        }
    }
}

/// 右边栏 tab 容器（D1）：顶部自绘 tab 条 + 按枚举 switch 渲染，不用 SwiftUI TabView
/// （避免其在 NavigationSplitView 右栏内的额外手势区与尺寸重算）。
/// 整列全屏（设计 D5）：tab 条右侧「⤢」入口 → .fullScreenCover 覆盖层铺满屏渲染同一容器，
/// 三 tab 通用、退出恢复原 inspector 列宽。
struct RightPanelContainerView: View {
    /// 当前选中 thread 的 cwd：审查「全量」拉取 + 文件浏览根均需要。
    var cwd: String?
    /// 当前选中主对话 threadId：侧聊从它 fork（无则空态、禁用「开始侧聊」）。
    var mainThreadId: String?

    @Environment(ConnectionStore.self) private var connection
    @Environment(ActiveConversationHolder.self) private var activeConversation
    // 全屏覆盖层脱离 inspector 列，侧聊 tab 会渲染 ConversationView→ComposerView 子树，
    // 后者读 ApprovalStore / EnvironmentStore；不补注入则侧聊全屏必崩（设计 D5 + 风险 3）。
    @Environment(ApprovalStore.self) private var approvals
    @Environment(EnvironmentStore.self) private var environmentStore
    @Environment(\.locale) private var locale
    // 快捷键经布局 store 发一次性右栏意图；本容器消费即复位（设计 D6）。
    @Environment(WorkspaceLayoutStore.self) private var layout

    @State private var selectedTab: RightPanelTab = .review
    @State private var fileBrowser = FileBrowserStore()
    @State private var sideChat = SideChatStore()
    @State private var isFullscreen = false

    var body: some View {
        baseContent
            .fullScreenCover(isPresented: $isFullscreen) {
                tabContainer
                    // 覆盖层脱离 inspector 独立列，不继承父链环境，显式注入所需依赖（设计 D5 + 风险 3）。
                    // 三 tab 子树的全部环境依赖：activeConversation/connection（审查·文件）、
                    // approvals/environmentStore（侧聊 ConversationView→ComposerView）、locale（i18n）。
                    .environment(activeConversation)
                    .environment(connection)
                    .environment(approvals)
                    .environment(environmentStore)
                    .environment(\.locale, locale)
            }
            .onChange(of: layout.pendingRightPanelIntent) { _, _ in
                consumeRightPanelIntent(layout.pendingRightPanelIntent)
            }
            .onAppear { consumeRightPanelIntent(layout.pendingRightPanelIntent) }
    }

    /// 消费一次性右栏意图（设计 D6）：tab 跳转 → 选中该 tab；全屏 → 切 isFullscreen；消费即复位。
    private func consumeRightPanelIntent(_ intent: RightPanelIntent?) {
        guard let intent else { return }
        if let tab = intent.targetTab {
            selectedTab = tab
        } else {   // toggleFullscreen（targetTab == nil）
            isFullscreen.toggle()
        }
        layout.pendingRightPanelIntent = nil   // 消费即复位，防回环（功耗约束 4）
    }

    /// base 层内容：全屏态让位给 cover，避免同一 `tabContainer` 在 base 与 cover 同时挂载。
    /// 关键：侧聊 tab 会挂 `ConversationView(threadId:)`，其 `.task` 会 startObserving+resume 并写
    /// 共享的 `activeConversation.{state,fetchFullDiff,startReview}`。若 base 与 cover 双挂载，会重复
    /// thread/resume + 双订阅，且退出全屏时 cover 的 `onDisappear` 会把 `startReview` 等清成 nil，
    /// clobber base 的注入（审查按钮失效）。全屏态下 base 只留占位背景，保住 inspector 列位（设计 D5 + 风险 3）。
    @ViewBuilder
    private var baseContent: some View {
        if isFullscreen {
            Color(.systemBackground)
        } else {
            tabContainer
        }
    }

    /// tab 条 + 内容 switch + 数据绑定 task，常规态与全屏覆盖层共用（保证三 tab 通用、状态一致）。
    private var tabContainer: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            switch selectedTab {
            case .review:
                ReviewTabView(cwd: cwd)
            case .files:
                FileBrowserView(store: fileBrowser)
            case .sideChat:
                SideChatView(store: sideChat, mainThreadId: mainThreadId)
            }
        }
        .task(id: fileBrowserKey) {
            guard connection.phase == .ready, let rpc = connection.rpc else { return }
            fileBrowser.attach(rpc: rpc)
            await fileBrowser.setRoot(cwd)
        }
        .task(id: connection.phase == .ready) {
            guard connection.phase == .ready, let rpc = connection.rpc else { return }
            sideChat.attach(rpc: rpc)
        }
    }

    // rpc 就绪态 + cwd 组合 key：任一变化即重跑 attach/setRoot。
    private var fileBrowserKey: String {
        "\(connection.phase == .ready)-\(cwd ?? "")"
    }

    // 自绘分段 tab 条（非 Picker/TabView）+ 右侧全屏/收起入口。
    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(RightPanelTab.allCases) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    Text(tab.label)
                        .font(.subheadline)
                        .fontWeight(selectedTab == tab ? .semibold : .regular)
                        .foregroundStyle(selectedTab == tab ? Color.accentColor : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selectedTab == tab ? [.isSelected] : [])
            }
            // 全屏 / 收起入口（容器级，三 tab 通用，设计 D5）。
            Button {
                isFullscreen.toggle()
            } label: {
                Image(systemName: isFullscreen
                      ? "arrow.down.right.and.arrow.up.left"
                      : "arrow.up.left.and.arrow.down.right")
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(isFullscreen ? "rightPanel.fullscreen.exit" : "rightPanel.fullscreen.enter"))
        }
        .background(.bar)
    }
}
