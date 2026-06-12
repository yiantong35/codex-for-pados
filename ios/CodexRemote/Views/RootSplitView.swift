import SwiftUI

/// 两列布局（设计 §3 / §D7）：sidebar（项目→对话树）| content（对话流），右栏环境信息改为
/// iOS 17 `.inspector(isPresented:)` 可显隐面板（复刻 desktop 右上角面板开关，默认收起）。
/// 默认展开侧栏（columnVisibility = .all），进来即见会话列表、默认聚焦侧栏、不强制选对话。
/// inspector 复刻 v1 简态：展示选中线程的 cwd / 分支 / 模型，未选中显示占位。
/// 设置齿轮移入 SidebarView 工具栏常驻，故此处顶层 toolbar 不再承载 SettingsMenu。
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
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selectedThreadId: $selectedThreadId)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
        } detail: {
            // 包进 NavigationStack：空态（Color.clear）也有稳定导航栏承载 toolbar，
            // 否则 .balanced 折叠侧栏后既无系统召回入口、也无处挂显式开关，侧栏召不回来。
            NavigationStack {
                content
                    .inspector(isPresented: $showInspector) {
                        InspectorView(thread: selectedThread)
                            // 允许拉得更窄（min 150，旧 220 太宽）。
                            .inspectorColumnWidth(min: 150, ideal: 240, max: 380)
                    }
                    .toolbar {
                        // leading 显式侧栏开关：侧栏收起后用户始终能点它召回（修目视反馈 bug）。
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                withAnimation {
                                    columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
                                }
                            } label: {
                                Label("sidebar.toggle", systemImage: "sidebar.leading")
                            }
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button { showInspector.toggle() } label: {
                                // 右侧面板观感图标，与左侧栏开关明显区分。
                                Label("inspector.toggle", systemImage: "rectangle.righthalf.inset.filled")
                            }
                        }
                    }
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    @ViewBuilder private var content: some View {
        if let id = selectedThreadId {
            // 选中对话时装配 ConversationStore（ConversationView 内用 connection.rpc 构造）。
            // id 作为 .id 触发键，切换对话时重建 store + startObserving + resume。
            ConversationView(threadId: id).id(id)
        } else {
            // 最小空态：不显大占位卡，默认聚焦侧栏。
            Color.clear
        }
    }
}
