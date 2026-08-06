import SwiftUI

/// composer 上方的进度卡片（design D5）。
/// 收起小条：⟳ 第 N/M 步 · X 个文件已更改 +A −B（spinner=accentColor 橙，+绿 −红，千位分隔）。
/// 展开 overlay：plan 步骤列表（复用 PlanStepList）+ 压暗 scrim。
/// 空态（无 plan 且无 diff）：调用方负责不渲染本视图。
struct ProgressCardBar: View {
    let progress: WorkspaceSummary.PlanProgress
    let diff: WorkspaceSummary.DiffLineCounts
    /// 点击「X 文件已更改」的回调（转跳右栏）。
    var onTapFiles: (() -> Void)?

    @State private var expanded = false

    init(progress: WorkspaceSummary.PlanProgress,
         diff: WorkspaceSummary.DiffLineCounts,
         initialExpanded: Bool = false,
         onTapFiles: (() -> Void)? = nil) {
        self.progress = progress
        self.diff = diff
        self.onTapFiles = onTapFiles
        _expanded = State(initialValue: initialExpanded)
    }

    private static let intFormatter: NumberFormatter = {
        let f = NumberFormatter(); f.numberStyle = .decimal; return f
    }()
    private func fmt(_ n: Int) -> String {
        Self.intFormatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    static func showsExpandControl(for progress: WorkspaceSummary.PlanProgress) -> Bool {
        !progress.isEmpty
    }

    static func showsFilesControl(diff: WorkspaceSummary.DiffLineCounts,
                                  hasAction: Bool) -> Bool {
        !diff.isEmpty && hasAction
    }

    var body: some View {
        collapsedBar
            .overlay(alignment: .bottom) {
                if expanded && !progress.isEmpty { expandedOverlay }
            }
            .onChange(of: progress.isEmpty) { _, isEmpty in
                if isEmpty { expanded = false }
            }
    }

    private var collapsedBar: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).tint(Color.accentColor)
            if Self.showsExpandControl(for: progress) {
                Button(action: toggleExpanded) {
                    HStack(spacing: 5) {
                        Text("progress.step \(progress.completed)/\(progress.total)")
                            .monospacedDigit()
                            .font(.callout)
                        Image(systemName: expanded ? "chevron.down" : "chevron.up")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .minimumHitTarget44()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(expanded ? "progress.collapse" : "progress.expand"))
                .accessibilityValue(Text("progress.step \(progress.completed)/\(progress.total)"))
            }
            if !progress.isEmpty && !diff.isEmpty {
                Text("·").foregroundStyle(.secondary)
            }
            if !diff.isEmpty {
                if let onTapFiles {
                    Button(action: onTapFiles) {
                        fileStats
                    }
                    .buttonStyle(.plain)
                    .minimumHitTarget44()
                } else {
                    fileStats
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 2)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator))
        .padding(.horizontal, 12)
    }

    private var fileStats: some View {
        HStack(spacing: 6) {
            Text("progress.filesChanged \(diff.changedFiles)").font(.callout)
            Text("+\(fmt(diff.added))").foregroundStyle(.green).monospacedDigit()
            Text("−\(fmt(diff.removed))").foregroundStyle(.red).monospacedDigit()
        }
    }

    private func toggleExpanded() {
        withAnimation { expanded.toggle() }
    }

    private var expandedOverlay: some View {
        VStack(alignment: .leading, spacing: 8) {
            PlanStepList(steps: progress.steps)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
        .padding(.horizontal, 12)
        .offset(y: -52)
        .alignmentGuide(.bottom) { $0[.top] }   // overlay 浮在小条上方
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}
