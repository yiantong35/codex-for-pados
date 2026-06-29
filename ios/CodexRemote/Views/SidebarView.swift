import SwiftUI

/// 左栏：按项目（同一 cwd）分组展示对话树。
/// 每个 Section = 一个项目（displayName + 文件夹图标）；其下逐条渲染 ThreadSummary。
/// 对话标题取 `name ?? preview`，副标题为相对时间；待批准的对话显示橙色徽标（复刻 desktop）。
/// 选中态通过 `selectedThreadId` 绑定回 NavigationSplitView。
struct SidebarView: View {
    @Environment(ProjectsStore.self) private var projects
    @Environment(ConnectionStore.self) private var connection
    @Binding var selectedThreadId: String?
    @State private var collapse = SidebarCollapseStore()

    var body: some View {
        // 不用 List(selection:)：系统 sidebar 选中会画一个方框（用户嫌丑 #4），且列隐藏再显示后丢失（#5）。
        // 改为自渲染选中态（threadRow 内点按选择 + 主题色），完全可控、持久、无方框。
        List {
            if projects.isGrouped {
                ForEach(projects.projects) { project in
                    projectSection(project)
                }
                if !projects.looseConversations.isEmpty {
                    Section("sidebar.conversations") {
                        ForEach(projects.looseConversations) { thread in
                            threadRow(thread).tag(thread.id)
                        }
                    }
                }
            } else {
                ForEach(projects.allThreadsSorted) { thread in
                    threadRow(thread).tag(thread.id)
                }
            }
        }
        .navigationTitle("sidebar.title")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    guard let rpc = connection.rpc else { return }
                    Task {
                        let any = try? await rpc.send(method: RPCMethod.threadStart,
                                                      params: AnyCodable(["cwd": nil, "model": nil] as [String: String?]))
                        if let dict = any?.value as? [String: Any],
                           let id = (dict["thread"] as? [String: Any])?["id"] as? String {
                            await MainActor.run {
                                selectedThreadId = id
                                // 新建即视为已读（标到当前时刻），避免切走再回误亮未读点。
                                projects.markViewed(threadId: id, updatedAt: Date().timeIntervalSince1970)
                            }
                        }
                    }
                } label: { Image(systemName: "square.and.pencil") }
                .accessibilityLabel(Text("sidebar.newThread"))
            }
        }
        .overlay {
            if projects.projects.isEmpty && projects.looseConversations.isEmpty {
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

    /// 单个项目 = 可折叠 DisclosureGroup；标题行带文件夹图标 + 待批准计数徽标。
    @ViewBuilder
    private func projectSection(_ project: Project) -> some View {
        let pending = projects.pendingApprovalCount(in: project)
        DisclosureGroup(isExpanded: Binding(
            get: { !collapse.isCollapsed(project.id) },
            set: { collapse.setCollapsed(project.id, !$0) }
        )) {
            ForEach(project.threads) { thread in
                threadRow(thread).tag(thread.id)
            }
        } label: {
            HStack {
                Label(project.displayName, systemImage: "folder")
                Spacer()
                if pending > 0 {
                    Text("\(pending)")
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.orange, in: Capsule())
                        .foregroundStyle(.white)
                        .accessibilityLabel(Text("sidebar.pendingApproval"))
                }
            }
        }
    }

    @ViewBuilder
    private func threadRow(_ thread: ThreadSummary) -> some View {
        // 选中态自渲染：左缘橙条 + 橙标题（不用方框）。点按整行选择。
        // 不依赖系统 List 选中高亮——后者方框丑（#4）且列隐藏再显示后会丢失（#5）。
        let selected = selectedThreadId == thread.id
        HStack(spacing: 8) {
            Capsule()
                .fill(selected ? Color.accentColor : Color.clear)
                .frame(width: 3, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayTitle(thread)).lineLimit(1)
                    .foregroundStyle(selected ? Color.accentColor : Color.primary)
                Text(Self.relativeTime(thread.updatedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // 运行态徽标（批次②，daemon ThreadStatus 来源）
            switch RunStateBadge.from(projects.status(of: thread.id)) {
            case .running:
                ProgressView().controlSize(.small)
            case .waitingInput:
                Image(systemName: "questionmark.circle.fill").foregroundStyle(.blue)
                    .accessibilityLabel(Text("sidebar.waitingInput"))
            case .waitingApproval:
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    .accessibilityLabel(Text("sidebar.pendingApproval"))
            case .error:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    .accessibilityLabel(Text("sidebar.systemError"))
            case .none:
                EmptyView()
            }
            // 未读活动点（批次②，本地；当前选中不亮）
            if projects.hasUnread(thread, isSelected: selected) {
                Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                    .accessibilityLabel(Text("sidebar.unread"))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            selectedThreadId = thread.id
            projects.markViewed(threadId: thread.id, updatedAt: thread.updatedAt)
        }
        .contextMenu {
            Button {
                guard let rpc = connection.rpc else { return }
                Task {
                    let any = try? await rpc.send(method: RPCMethod.threadFork,
                                                  params: AnyCodable(["threadId": thread.id]))
                    if let dict = any?.value as? [String: Any],
                       let id = (dict["thread"] as? [String: Any])?["id"] as? String {
                        await MainActor.run { selectedThreadId = id }
                    }
                }
            } label: { Label("sidebar.fork", systemImage: "arrow.triangle.branch") }
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
