import SwiftUI

/// 左栏：按项目（同一 cwd）分组展示对话树。
/// 每个 Section = 一个项目（displayName + 文件夹图标）；其下逐条渲染 ThreadSummary。
/// 对话标题取 `name ?? preview`，副标题为相对时间；待批准的对话显示橙色徽标（复刻 desktop）。
/// 选中态通过 `selectedThreadId` 绑定回 NavigationSplitView。
struct SidebarView: View {
    @Environment(ProjectsStore.self) private var projects
    @Environment(ConnectionStore.self) private var connection
    @Binding var selectedThreadId: String?

    var body: some View {
        List(selection: $selectedThreadId) {
            ForEach(projects.projects) { project in
                Section {
                    ForEach(project.threads) { thread in
                        threadRow(thread).tag(thread.id)
                    }
                } header: {
                    Label(project.displayName, systemImage: "folder")
                }
            }
        }
        .navigationTitle("sidebar.title")
        .overlay {
            if projects.projects.isEmpty {
                ContentUnavailableView("sidebar.empty.title", systemImage: "tray",
                                       description: Text("sidebar.empty.desc"))
            }
        }
        .task(id: connection.phase) {
            // ready 后拉取 thread/list 填充 ProjectsStore；失败静默（store 内部处理）。
            guard connection.phase == .ready, let rpc = connection.rpc else { return }
            await projects.loadFromServer(rpc: rpc)
        }
    }

    @ViewBuilder
    private func threadRow(_ thread: ThreadSummary) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(displayTitle(thread)).lineLimit(1)
                Text(Self.relativeTime(thread.updatedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if projects.hasPendingApproval(thread.id) {
                Label("sidebar.pendingApproval", systemImage: "clock.badge.exclamationmark")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.orange)
                    .accessibilityLabel(Text("sidebar.pendingApproval"))
            }
        }
    }

    private func displayTitle(_ thread: ThreadSummary) -> String {
        if let name = thread.name, !name.isEmpty { return name }
        return thread.preview.isEmpty ? String(localized: "sidebar.untitled") : thread.preview
    }

    private static let formatter = RelativeDateTimeFormatter()

    private static func relativeTime(_ ts: Double) -> String {
        formatter.localizedString(for: Date(timeIntervalSince1970: ts), relativeTo: Date())
    }
}
