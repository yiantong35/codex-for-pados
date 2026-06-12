import SwiftUI

/// 两栏布局（设计 §3）：sidebar（项目→对话树）| detail（对话流）。
/// 默认展开侧栏（columnVisibility = .all），进来即见会话列表、不强制选对话。
/// 右侧「环境信息」面板（复刻 desktop）属 v2+，本期不做，故移除空占位列。
struct RootSplitView: View {
    @Environment(ConnectionStore.self) private var connection
    @State private var selectedThreadId: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selectedThreadId: $selectedThreadId)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
        } detail: {
            if let id = selectedThreadId {
                // 选中对话时装配 ConversationStore（ConversationView 内用 connection.rpc 构造）。
                // id 作为 .task(id:) 触发键，切换对话时重建 store + startObserving + resume。
                ConversationView(threadId: id)
                    .id(id)
            } else {
                ContentUnavailableView("split.selectConversation",
                                       systemImage: "bubble.left.and.bubble.right")
            }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { SettingsMenu() }
        }
    }
}
