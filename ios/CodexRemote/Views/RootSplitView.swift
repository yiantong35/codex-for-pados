import SwiftUI

/// 主界面（复刻 Codex desktop）：顶部固定全局工具栏 + 下方 NavigationSplitView（侧栏｜对话｜inspector）。
/// 所有全局按钮（侧栏开关 / 设置 / inspector 开关）钉在顶部固定栏，不随列折叠消失、不与系统开关重复。
/// 故清除各列系统自动工具栏项；侧栏显隐与 inspector 显隐均由顶部栏按钮显式控制。
struct RootSplitView: View {
    @Environment(ConnectionStore.self) private var connection
    @Environment(ProjectsStore.self) private var projects
    @State private var selectedThreadId: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showInspector = false   // 复刻 desktop：默认隐藏

    private var selectedThread: ThreadSummary? {
        guard let id = selectedThreadId else { return nil }
        return projects.allThreadsSorted.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            split
        }
    }

    // MARK: - 顶部固定全局工具栏（复刻 desktop title bar 的全局按钮区）

    private var topBar: some View {
        HStack(spacing: 18) {
            // 侧栏开关：固定常驻，展开/折叠都在，永远能召回侧栏。
            Button {
                withAnimation {
                    columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
                }
            } label: {
                Image(systemName: "sidebar.leading")
            }
            .accessibilityLabel(Text("sidebar.toggle"))

            Spacer()

            // 全局设置（复刻 desktop 右上角齿轮）。
            SettingsMenu()

            // inspector（环境信息）显隐开关。
            Button { showInspector.toggle() } label: {
                // TODO: 图标待 Codex 真实 inspector toggle 调查结果落地。
                Image(systemName: "list.bullet.rectangle")
            }
            .accessibilityLabel(Text("inspector.toggle"))
        }
        .font(.title3)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - 下方三栏（隐藏各列系统导航栏，全局按钮统一走顶部固定栏）

    private var split: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selectedThreadId: $selectedThreadId)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
                .toolbar(removing: .sidebarToggle)
                .toolbarBackground(.hidden, for: .navigationBar)
        } detail: {
            content
                .inspector(isPresented: $showInspector) {
                    InspectorView(thread: selectedThread)
                        .inspectorColumnWidth(min: 150, ideal: 240, max: 380)
                }
                .toolbar(removing: .sidebarToggle)
        }
        .navigationSplitViewStyle(.balanced)
    }

    @ViewBuilder private var content: some View {
        if let id = selectedThreadId {
            ConversationView(threadId: id).id(id)
        } else {
            Color(.systemBackground)
        }
    }
}
