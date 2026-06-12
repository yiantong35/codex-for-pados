import SwiftUI

/// 三栏布局（设计 §3 / §D7）：sidebar（项目→对话树）| content（对话流）| detail（环境信息 inspector）。
/// 默认展开侧栏（columnVisibility = .all），进来即见会话列表、不强制选对话。
/// 右栏 inspector 复刻 v1 简态：展示选中线程的 cwd / 分支 / 模型，未选中显示占位。
struct RootSplitView: View {
    @Environment(ConnectionStore.self) private var connection
    @Environment(ProjectsStore.self) private var projects
    @State private var selectedThreadId: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    private var selectedThread: ThreadSummary? {
        guard let id = selectedThreadId else { return nil }
        return projects.allThreadsSorted.first { $0.id == id }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selectedThreadId: $selectedThreadId)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
        } content: {
            if let id = selectedThreadId {
                // 选中对话时装配 ConversationStore（ConversationView 内用 connection.rpc 构造）。
                // id 作为 .task(id:) 触发键，切换对话时重建 store + startObserving + resume。
                ConversationView(threadId: id)
                    .id(id)
            } else {
                ContentUnavailableView("split.selectConversation",
                                       systemImage: "bubble.left.and.bubble.right")
            }
        } detail: {
            InspectorView(thread: selectedThread)
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 360)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { SettingsMenu() }
        }
    }
}
