import SwiftUI

/// 三栏骨架（设计 §3/D7）：sidebar（项目→对话树）| content（对话流，Task 15 接入）| detail（检视器）。
/// 横屏三列并排；竖屏由 NavigationSplitView 原生折叠为抽屉，无需手动处理。
struct RootSplitView: View {
    @Environment(ConnectionStore.self) private var connection
    @State private var selectedThreadId: String?

    var body: some View {
        NavigationSplitView {
            SidebarView(selectedThreadId: $selectedThreadId)
        } content: {
            if let id = selectedThreadId {
                // 选中对话时装配 ConversationStore（ConversationView 内用 connection.rpc 构造）。
                // id 作为 .task(id:) 触发键，切换对话时重建 store + startObserving + resume。
                ConversationView(threadId: id)
                    .id(id)
            } else {
                ContentUnavailableView("选择一个对话",
                                       systemImage: "bubble.left.and.bubble.right")
            }
        } detail: {
            InspectorPlaceholderView()
        }
    }
}

/// 右栏检视器占位（v1 简态，富态留 v2+）。
struct InspectorPlaceholderView: View {
    var body: some View {
        ContentUnavailableView("输出 / 来源", systemImage: "sidebar.right")
    }
}
