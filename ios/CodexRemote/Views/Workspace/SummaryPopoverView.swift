import SwiftUI

/// 摘要悬浮浮层内容（design D2）：diff 行数 / cwd / 进度(plan) / 任务(命令)。
/// 输入为当前会话状态与选中线程；全无数据时显空态。内容自适应（List 高度随内容）。
struct SummaryPopoverView: View {
    let state: ConversationState?
    let thread: ThreadSummary?
    var env: EnvironmentInspectorModel? = nil          // 批次⑤：全量 diff + 认证
    var onOpenReview: (() -> Void)? = nil              // 批次⑤：变更→审查面板跳转信号（后续接）

    private var diff: WorkspaceSummary.DiffLineCounts {
        state.map(WorkspaceSummary.diffLineCounts(in:)) ?? .init(added: 0, removed: 0, changedFiles: 0)
    }
    private var progress: WorkspaceSummary.PlanProgress {
        state.map(WorkspaceSummary.planProgress(in:)) ?? .init(steps: [])
    }
    private var tasks: [WorkspaceSummary.CommandTask] {
        state.map(WorkspaceSummary.commandTasks(in:)) ?? []
    }
    private var cwd: String? { thread?.cwd }
    private var subAgents: [SubAgentState] {           // 批次⑤：当前会话子智能体（按名排序）
        (state?.subAgents.values).map { Array($0).sorted { $0.displayName < $1.displayName } } ?? []
    }
    private var hasEnv: Bool {
        (env?.diffStats?.isEmpty == false) || env?.authStatus != nil || !subAgents.isEmpty
            || (thread?.gitInfo?.branch != nil)
    }

    private var isEmpty: Bool {
        diff.isEmpty && progress.isEmpty && tasks.isEmpty && (cwd?.isEmpty ?? true) && !hasEnv
    }

    var body: some View {
        if isEmpty {
            ContentUnavailableView("workspace.summary.empty", systemImage: "list.bullet.rectangle")
                .padding()
        } else {
            List {
                // 批次⑤：全量变更（总数 + 跳转信号）
                if let stats = env?.diffStats, !stats.isEmpty {
                    Section("workspace.env.changes") {
                        Button { onOpenReview?() } label: {
                            HStack {
                                Text("+\(stats.added)  −\(stats.removed)  ·  \(stats.changedFiles)").monospacedDigit()
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.secondary)
                            }
                        }
                        .disabled(onOpenReview == nil)
                    }
                }
                // 批次⑤：分支/SHA
                if let git = thread?.gitInfo, git.branch != nil || git.sha != nil {
                    Section("workspace.env.branch") {
                        if let b = git.branch { LabeledContent("workspace.env.branchName", value: b) }
                        if let s = git.sha { LabeledContent("workspace.env.sha", value: String(s.prefix(8))) }
                    }
                }
                // 批次⑤：GitHub 认证
                if let auth = env?.authStatus {
                    Section("workspace.env.auth") {
                        let ok = (auth.requiresOpenaiAuth == false) || (auth.authToken != nil)
                        LabeledContent("workspace.env.authStatus",
                                       value: String(localized: ok ? "workspace.env.authed" : "workspace.env.unauthed"))
                    }
                }
                // 批次⑤：子智能体
                if !subAgents.isEmpty {
                    Section("workspace.env.subagents") {
                        ForEach(subAgents) { a in
                            HStack {
                                Text(a.displayName).lineLimit(1)
                                Spacer()
                                Text(Self.statusLabel(a.status)).font(.caption)
                                    .foregroundStyle(Self.statusColor(a.status))
                            }
                        }
                    }
                }
                if !diff.isEmpty {
                    Section("workspace.summary.diff") {
                        Text("+\(diff.added)  −\(diff.removed)  ·  \(diff.changedFiles)")
                            .monospacedDigit()
                    }
                }
                if let cwd, !cwd.isEmpty {
                    Section("workspace.summary.cwd") {
                        Text(cwd).lineLimit(2).font(.callout)
                    }
                }
                if !progress.isEmpty {
                    Section {
                        PlanStepList(steps: progress.steps)
                    } header: {
                        // 标题用本地化键，计数用 verbatim 追加，避免 LocalizedStringKey
                        // 插值把查找键变成 "workspace.summary.progress %lld %lld"（catalog 无此键 → 回落键名）。
                        Text("workspace.summary.progress")
                            + Text(verbatim: " \(progress.completed)/\(progress.total)").monospacedDigit()
                    }
                }
                if !tasks.isEmpty {
                    Section("workspace.summary.tasks") {
                        ForEach(tasks) { task in
                            Text(task.command).font(.caption).monospaced().lineLimit(1)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    // 批次⑤：子智能体状态文案/颜色
    private static func statusLabel(_ s: CollabAgentStatus) -> String {
        switch s {
        case .pendingInit: return String(localized: "workspace.env.sa.pending")
        case .running:     return String(localized: "workspace.env.sa.running")
        case .interrupted: return String(localized: "workspace.env.sa.interrupted")
        case .completed:   return String(localized: "workspace.env.sa.completed")
        case .errored:     return String(localized: "workspace.env.sa.errored")
        case .shutdown:    return String(localized: "workspace.env.sa.shutdown")
        case .notFound:    return String(localized: "workspace.env.sa.notFound")
        }
    }
    private static func statusColor(_ s: CollabAgentStatus) -> Color {
        switch s {
        case .running:            return .accentColor
        case .completed:          return .green
        case .errored:            return .red
        case .interrupted, .shutdown, .notFound: return .secondary
        case .pendingInit:        return .orange
        }
    }
}
