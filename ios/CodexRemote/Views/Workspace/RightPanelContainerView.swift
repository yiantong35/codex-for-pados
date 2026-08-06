import SwiftUI

/// 右栏 tab 标识（D1）。三个 tab：审查 / 文件 / 侧聊。
enum RightPanelTab: CaseIterable, Identifiable {
    case review, files, sideChat
    var id: Self { self }
    /// D5：tab 名跟随注入 locale（不用 `String(localized:)`，它忽略应用内注入 locale）。
    func label(locale: Locale) -> String {
        switch self {
        case .review:   return L10n.string("rightPanel.tab.review", locale: locale)
        case .files:    return L10n.string("rightPanel.tab.files", locale: locale)
        case .sideChat: return L10n.string("rightPanel.tab.sideChat", locale: locale)
        }
    }
}

/// 右边栏 tab 容器（D1）：顶部自绘 tab 条 + 按枚举 switch 渲染，不用 SwiftUI TabView
/// （避免其在自绘右列内的额外手势区与尺寸重算）。
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
    // 全屏切换快捷键：进入路径由 base 层 ShortcutLayer 承载，但覆盖层为 .fullScreenCover 模态，
    // 会脱离 presenter 的响应链——退出路径必须在 cover 自身内部再挂一枚隐藏快捷键按钮才能双向切换（M1）。
    @Environment(ShortcutStore.self) private var shortcuts

    @Environment(FileBrowserStore.self) private var fileBrowser
    @Environment(SideChatStore.self) private var sideChat
    @Binding var selectedTab: RightPanelTab
    @State private var isFullscreen = false

    init(cwd: String? = nil,
         mainThreadId: String? = nil,
         selectedTab: Binding<RightPanelTab> = .constant(.review)) {
        self.cwd = cwd
        self.mainThreadId = mainThreadId
        self._selectedTab = selectedTab
    }

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
                    // 退出全屏快捷键宿主（M1）：⌘⌃F 只挂在 base 层 ShortcutLayer 时，覆盖层一旦present
                    // 就把 presenter 的 key command 挤出响应链，导致只进不出。故在 cover 内部再挂一枚
                    // 隐藏切换按钮（mirror ShortcutLayer 的 opacity-0 + 零尺寸 + 无障碍隐藏），使全屏态下
                    // ⌘⌃F 仍能切回常规列宽（可见的「⤢/收起」按钮保持不变，一并保留）。
                    .background {
                        Button("") { isFullscreen.toggle() }
                            .keyboardShortcut(shortcuts.combo(for: .rightPanelFullscreen).keyboardShortcut)
                            .opacity(0)
                            .frame(width: 0, height: 0)
                            .accessibilityHidden(true)
                    }
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
    // D3 修复：原实现每个标签各 maxWidth:.infinity 但尾部全屏按钮未定宽 → 极窄宽下首个
    // infinity 吞掉剩余空间、后续 tab 被裁。改为三标签等分（infinity 均分而非独占）+
    // 文字降级 minimumScaleFactor 兜底 + 全屏入口 fixedSize() 退出对 tab 区的宽度竞争。
    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(RightPanelTab.allCases) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    Text(tab.label(locale: locale))
                        .font(.subheadline)
                        .fontWeight(selectedTab == tab ? .semibold : .regular)
                        .foregroundStyle(selectedTab == tab ? Color.accentColor : Color.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)          // 窄宽文字降级，不撑破
                        .frame(maxWidth: .infinity)       // 三 tab 之间等分（每个都 infinity → 均分，不再是首个独占）
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())        // 留白也可命中
                }
                .buttonStyle(.plain)
                .layoutPriority(1)                        // tab 优先于尾部入口占据 tab 区
                .accessibilityAddTraits(selectedTab == tab ? [.isSelected] : [])
            }
            // 全屏 / 收起入口（容器级，三 tab 通用，设计 D5）：固定占位、不参与 tab 等分、不挤占 tab 命中区。
            Button {
                isFullscreen.toggle()
            } label: {
                Image(systemName: isFullscreen
                      ? "arrow.down.right.and.arrow.up.left"
                      : "arrow.up.left.and.arrow.down.right")
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .minimumHitTarget44()
            .fixedSize()                                  // 固定自身尺寸，不吸收也不挤占 tab 区
            .accessibilityLabel(Text(isFullscreen ? "rightPanel.fullscreen.exit" : "rightPanel.fullscreen.enter"))
        }
        .background(.bar)
    }
}
