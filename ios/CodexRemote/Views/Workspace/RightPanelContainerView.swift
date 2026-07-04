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
struct RightPanelContainerView: View {
    /// 当前选中 thread 的 cwd：审查「全量」拉取 + 文件浏览根均需要。
    var cwd: String?
    /// 当前选中主对话 threadId：侧聊从它 fork（无则空态、禁用「开始侧聊」）。
    var mainThreadId: String?

    @Environment(ConnectionStore.self) private var connection

    @State private var selectedTab: RightPanelTab = .review
    @State private var fileBrowser = FileBrowserStore()
    @State private var sideChat = SideChatStore()

    var body: some View {
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

    // 自绘分段 tab 条（非 Picker/TabView）。
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
        }
        .background(.bar)
    }
}
