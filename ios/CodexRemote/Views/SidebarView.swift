import SwiftUI

/// 左栏：按项目（同一 cwd）分组展示对话树。
/// 每个 Section = 一个项目（displayName + 文件夹图标）；其下逐条渲染 ThreadSummary。
/// 对话标题取 `name ?? preview`，副标题为相对时间；待批准的对话显示橙色徽标（复刻 desktop）。
/// 选中态通过 `selectedThreadId` 绑定回 RootSplitView（自绘三栏，已移除 NavigationSplitView）。
struct SidebarView: View {
    @MainActor private static var relativeTimeFormatters: [String: RelativeDateTimeFormatter] = [:]
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(ProjectsStore.self) private var projects
    @Environment(ConnectionStore.self) private var connection
    @Environment(EnvironmentStore.self) private var env
    @Environment(ActiveConversationHolder.self) private var activeConversation
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.locale) private var locale
    @Binding var selectedThreadId: String?
    @State private var collapse = SidebarCollapseStore()
    @State private var operationError: String?
    @State private var searchText = ""
    @State private var renameTarget: ThreadSummary?
    @State private var deleteTarget: ThreadSummary?
    @State private var rollbackTarget: ThreadSummary?
    @State private var rollbackTurns = 1
    @State private var goalTarget: ThreadSummary?

    var body: some View {
        // 不用 List(selection:)：系统 sidebar 选中会画一个方框（用户嫌丑 #4），且列隐藏再显示后丢失（#5）。
        // 改为自渲染选中态（threadRow 内点按选择 + 主题色），完全可控、持久、无方框。
        VStack(spacing: 0) {
            WorkspaceHeader {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("sidebar.search.placeholder", text: $searchText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .minimumHitTarget44()
                            .accessibilityLabel(Text("common.clear"))
                    }
                }
                .padding(.horizontal, 10)
            }
            Divider()

            List {
            if !searchText.isEmpty {
                ForEach(filteredThreads) { thread in
                    threadRow(thread).tag(thread.id)
                }
            } else if projects.isGrouped {
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
            .listStyle(.plain)
            .contentMargins(.horizontal, 4, for: .scrollContent)
            .environment(\.defaultMinListRowHeight, 44)
            .overlay {
                if !searchText.isEmpty && filteredThreads.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else if projects.projects.isEmpty && projects.looseConversations.isEmpty {
                    sidebarEmptyOverlay
                }
            }
        }
        .task(id: connection.phase) {
            // ready 后接线：attach（启动官方广播监听，D5-a）+ 首拉 thread/list 填充。
            guard connection.phase == .ready, let rpc = connection.rpc else {
                projects.stopPolling()
                return
            }
            await projects.attach(rpc: rpc)
            await env.attach(rpc: rpc)   // 拉 config/model-list，供 composer 服务器驱动选模型
            await projects.loadFromServer(rpc: rpc)
            // #6：首拉是 await——期间可能切标签/视图消失/进后台。仅在仍可见且未取消时才启动轮询，
            // 否则会覆盖 onDisappear/scenePhase 的停止。取消检测用 Task.isCancelled（覆盖视图消失/切标签）；
            // 前台判定读 connection.foregroundActive（app 级前后台的实时真源）而非闭包捕获的 scenePhase
            // ——运行中的 .task 闭包持任务启动时的 View 快照，await 后再读 scenePhase 会拿到过期的 .active，
            // 致「首拉期间进系统后台」这一场景仍误启后台轮询。foregroundActive 由 setAppForegroundAll 实时写入。
            guard !Task.isCancelled, connection.foregroundActive else { return }
            projects.startPolling(isVisible: true)   // D5-b：列表可见即准实时轮询
        }
        .onDisappear { projects.stopPolling() }
        .onChange(of: scenePhase) { _, phase in
            // D5-b：前台/获焦立即刷新并轮询；退后台暂停轮询省电。
            switch phase {
            case .active:
                projects.startPolling()
                Task { await projects.refreshNow() }
            case .background, .inactive:
                projects.stopPolling()
            @unknown default: break
            }
        }
        .alert("operation.failed.title", isPresented: Binding(
            get: { operationError != nil },
            set: { if !$0 { operationError = nil } }
        )) {
            Button("common.ok", role: .cancel) { operationError = nil }
        } message: {
            Text(operationError ?? "")
        }
        .sheet(item: $renameTarget) { thread in
            ThreadRenameSheet(thread: thread) { name in
                await projects.rename(threadId: thread.id, name: name)
            }
        }
        .sheet(item: $goalTarget) { thread in
            ThreadGoalEditorSheet(thread: thread)
                .environment(projects)
        }
        .confirmationDialog(deleteConfirmationTitle, isPresented: Binding(
            get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }
        ), titleVisibility: .visible) {
            Button("sidebar.delete", role: .destructive) {
                guard let thread = deleteTarget else { return }
                deleteTarget = nil
                perform(thread: thread, clearsSelection: true) {
                    await projects.delete(threadId: thread.id)
                }
            }
            Button("common.cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("sidebar.delete.confirm.message")
        }
        .confirmationDialog(rollbackConfirmationTitle, isPresented: Binding(
            get: { rollbackTarget != nil }, set: { if !$0 { rollbackTarget = nil } }
        ), titleVisibility: .visible) {
            Button("sidebar.rollback.confirm \(rollbackTurns)", role: .destructive) {
                guard let thread = rollbackTarget else { return }
                rollbackTarget = nil
                perform(thread: thread) {
                    await projects.rollback(threadId: thread.id, numTurns: rollbackTurns) { result in
                        activeConversation.applyThreadSnapshot?(thread.id, result)
                    }
                }
            }
            Button("common.cancel", role: .cancel) { rollbackTarget = nil }
        } message: {
            Text("sidebar.rollback.confirm.message \(rollbackTurns)")
        }
    }

    @ViewBuilder
    private var sidebarEmptyOverlay: some View {
        if connection.phase == .disconnected {
            WorkspaceEmptyState(
                title: "sidebar.loadFailed.title",
                description: "sidebar.disconnected.desc",
                systemImage: "wifi.slash"
            )
        } else if case .failed = connection.phase {
            WorkspaceEmptyState(
                title: "sidebar.loadFailed.title",
                description: "sidebar.disconnected.desc",
                systemImage: "wifi.exclamationmark"
            )
        } else {
            switch projects.loadState {
        case .idle, .loading:
            ProgressView("sidebar.loading")
        case .failed:
            WorkspaceEmptyState(
                title: "sidebar.loadFailed.title",
                description: "sidebar.loadFailed.desc",
                systemImage: "wifi.exclamationmark",
                actionTitle: "sidebar.retry",
                action: {
                    guard let rpc = connection.rpc else { return }
                    Task { await projects.loadFromServer(rpc: rpc) }
                }
            )
        case .loaded:
            WorkspaceEmptyState(
                title: "sidebar.empty.title",
                description: "sidebar.empty.desc",
                systemImage: "tray"
            )
            }
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
        // D7（2.7）：整行改 Button 语义（原 .onTapGesture 无按钮 trait/无键盘可达）。
        // .buttonStyle(.plain) 保留自绘选中态视觉（左缘橙条 + 橙标题），不引入系统高亮方框。
        HStack(spacing: 0) {
            Button {
                selectedThreadId = thread.id
                projects.markViewed(threadId: thread.id, updatedAt: thread.updatedAt)
            } label: {
                threadRowContent(thread, selected: selected)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? [.isSelected] : [])

            Menu {
                threadActions(thread)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(Text("sidebar.actions \(displayTitle(thread))"))
        }
        .frame(minHeight: 44)
        .contextMenu { threadActions(thread) }
    }

    @ViewBuilder
    private func threadRowContent(_ thread: ThreadSummary, selected: Bool) -> some View {
        HStack(spacing: 8) {
            Capsule()
                .fill(selected ? Color.accentColor : Color.clear)
                .frame(width: 3, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayTitle(thread)).lineLimit(1)
                    .foregroundStyle(selected ? Color.accentColor : Color.primary)
                if !dynamicTypeSize.isAccessibilitySize {
                    Text(Self.relativeTime(thread.updatedAt, locale: locale))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
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
        .frame(minHeight: 44)
    }

    @ViewBuilder
    private func threadActions(_ thread: ThreadSummary) -> some View {
        Button {
            renameTarget = thread
        } label: { Label("sidebar.rename", systemImage: "pencil") }

        Button {
            perform(thread: thread) { await projects.archive(threadId: thread.id) }
        } label: { Label("sidebar.archive", systemImage: "archivebox") }

        Button {
            goalTarget = thread
        } label: { Label("sidebar.goal", systemImage: "target") }

        Menu("sidebar.rollback", systemImage: "arrow.uturn.backward") {
            ForEach([1, 2, 5], id: \.self) { turns in
                Button("sidebar.rollback.turns \(turns)") {
                    rollbackTurns = turns
                    rollbackTarget = thread
                }
            }
        }

        Button {
            perform(thread: thread) { await projects.compact(threadId: thread.id) }
        } label: { Label("sidebar.compact", systemImage: "arrow.down.right.and.arrow.up.left") }

        Button {
            guard connection.phase == .ready, let rpc = connection.rpc else {
                operationError = L10n.string("operation.unavailable.offline", locale: locale)
                return
            }
            Task {
                do {
                    let any = try await rpc.send(method: RPCMethod.threadFork,
                                                 params: AnyCodable(["threadId": thread.id]))
                    if let dict = any.value as? [String: Any],
                       let id = (dict["thread"] as? [String: Any])?["id"] as? String {
                        selectedThreadId = id
                    } else {
                        operationError = L10n.string("operation.failed.description", locale: locale)
                    }
                } catch {
                    operationError = L10n.string("operation.failed.description", locale: locale)
                }
            }
        } label: { Label("sidebar.fork", systemImage: "arrow.triangle.branch") }
            .disabled(connection.phase != .ready)

        Divider()
        Button(role: .destructive) {
            deleteTarget = thread
        } label: { Label("sidebar.delete", systemImage: "trash") }
    }

    private var deleteConfirmationTitle: String {
        guard let deleteTarget else { return "" }
        return String.localizedStringWithFormat(
            L10n.string("sidebar.delete.confirm.named %@", locale: locale),
            displayTitle(deleteTarget)
        )
    }

    private var rollbackConfirmationTitle: String {
        guard let rollbackTarget else { return "" }
        return String.localizedStringWithFormat(
            L10n.string("sidebar.rollback.confirm.named %@", locale: locale),
            displayTitle(rollbackTarget)
        )
    }

    private var filteredThreads: [ThreadSummary] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return projects.allThreadsSorted }
        return projects.allThreadsSorted.filter { thread in
            [thread.name, thread.preview, thread.cwd]
                .compactMap { $0 }
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private func perform(thread: ThreadSummary,
                         clearsSelection: Bool = false,
                         action: @escaping @MainActor () async -> Bool) {
        guard connection.phase == .ready else {
            operationError = L10n.string("operation.unavailable.offline", locale: locale)
            return
        }
        Task {
            if await action() {
                if clearsSelection, selectedThreadId == thread.id { selectedThreadId = nil }
            } else {
                operationError = L10n.string("operation.failed.description", locale: locale)
            }
        }
    }

    private func displayTitle(_ thread: ThreadSummary) -> String {
        if let name = thread.name, !name.isEmpty { return name }
        return thread.preview.isEmpty ? L10n.string("sidebar.untitled", locale: locale) : thread.preview
    }

    static func relativeTime(_ ts: Double, locale: Locale) -> String {
        let key = locale.identifier
        let formatter: RelativeDateTimeFormatter
        if let cached = relativeTimeFormatters[key] {
            formatter = cached
        } else {
            let created = RelativeDateTimeFormatter()
            created.locale = locale
            relativeTimeFormatters[key] = created
            formatter = created
        }
        return formatter.localizedString(for: Date(timeIntervalSince1970: ts), relativeTo: Date())
    }
}

private struct ThreadRenameSheet: View {
    let thread: ThreadSummary
    let save: @MainActor (String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var isSaving = false
    @State private var failed = false

    init(thread: ThreadSummary, save: @escaping @MainActor (String) async -> Bool) {
        self.thread = thread
        self.save = save
        _name = State(initialValue: thread.name ?? thread.preview)
    }

    var body: some View {
        NavigationStack {
            Form { TextField("sidebar.rename.placeholder", text: $name) }
                .navigationTitle("sidebar.rename")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("common.cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("common.save") {
                            isSaving = true
                            Task {
                                if await save(name.trimmingCharacters(in: .whitespacesAndNewlines)) {
                                    dismiss()
                                } else {
                                    failed = true
                                    isSaving = false
                                }
                            }
                        }
                        .disabled(isSaving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .alert("operation.failed.title", isPresented: $failed) {
                    Button("common.ok", role: .cancel) {}
                } message: { Text("operation.failed.description") }
        }
        .presentationDetents([.medium])
    }
}

private struct ThreadGoalEditorSheet: View {
    let thread: ThreadSummary
    @Environment(ProjectsStore.self) private var projects
    @Environment(\.dismiss) private var dismiss
    @State private var objective = ""
    @State private var status: ThreadGoalStatus = .active
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var hasGoal = false
    @State private var loadFailed = false
    @State private var failed = false
    @State private var showClearConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                if isLoading {
                    ProgressView("common.loading")
                } else if loadFailed {
                    ContentUnavailableView {
                        Label("operation.failed.title", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text("operation.failed.description")
                    } actions: {
                        Button("common.retry") { Task { await loadGoal() } }
                            .frame(minHeight: 44)
                    }
                } else {
                    Section("sidebar.goal.objective") {
                        TextEditor(text: $objective).frame(minHeight: 100)
                    }
                    Picker("sidebar.goal.status", selection: $status) {
                        ForEach(ThreadGoalStatus.allCases, id: \.self) { value in
                            Text(LocalizedStringKey("sidebar.goal.status.\(value.rawValue)"))
                                .tag(value)
                        }
                    }
                    if hasGoal {
                        Button("sidebar.goal.clear", role: .destructive) {
                            showClearConfirmation = true
                        }
                    }
                }
            }
            .confirmationDialog("sidebar.goal.clear.confirm.title",
                                isPresented: $showClearConfirmation,
                                titleVisibility: .visible) {
                Button("sidebar.goal.clear", role: .destructive) {
                    isSaving = true
                    Task {
                        if await projects.clearGoal(threadId: thread.id) { dismiss() }
                        else { failed = true; isSaving = false }
                    }
                }
                Button("common.cancel", role: .cancel) {}
            } message: {
                Text("sidebar.goal.clear.confirm.message")
            }
            .navigationTitle("sidebar.goal")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.save") {
                        isSaving = true
                        Task {
                            let value = objective.trimmingCharacters(in: .whitespacesAndNewlines)
                            if await projects.setGoal(threadId: thread.id, objective: value, status: status) {
                                dismiss()
                            } else { failed = true; isSaving = false }
                        }
                    }
                    .disabled(isLoading || isSaving || objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .task { await loadGoal() }
            .alert("operation.failed.title", isPresented: $failed) {
                Button("common.ok", role: .cancel) {}
            } message: { Text("operation.failed.description") }
        }
        .presentationDetents([.medium, .large])
    }

    private func loadGoal() async {
        isLoading = true
        loadFailed = false
        do {
            if let goal = try await projects.fetchGoal(threadId: thread.id) {
                objective = goal.objective
                status = goal.status
                hasGoal = true
            } else {
                objective = ""
                status = .active
                hasGoal = false
            }
        } catch {
            loadFailed = true
        }
        isLoading = false
    }
}

private extension ThreadGoalStatus {
    static var allCases: [ThreadGoalStatus] {
        [.active, .paused, .blocked, .usageLimited, .budgetLimited, .complete]
    }
}
