import SwiftUI

/// 摘要悬浮浮层内容（design D2）：diff 行数 / cwd / 进度(plan) / 任务(命令)。
/// 输入为当前会话状态与选中线程；全无数据时显空态。内容自适应（List 高度随内容）。
struct SummaryPopoverView: View {
    let state: ConversationState?
    let thread: ThreadSummary?

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

    private var isEmpty: Bool {
        diff.isEmpty && progress.isEmpty && tasks.isEmpty && (cwd?.isEmpty ?? true)
    }

    var body: some View {
        if isEmpty {
            ContentUnavailableView("workspace.summary.empty", systemImage: "list.bullet.rectangle")
                .padding()
        } else {
            List {
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

}
