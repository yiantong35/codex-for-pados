import SwiftUI

/// 审查 tab：数据源切换（本轮/全量）+ 逐行红绿 diff（ReviewPanelView）+ AI 审查发起入口。
/// 发起入口跟随当前数据源（设计 D1）：本轮→custom{turnDiff}、全量→uncommittedChanges，
/// 经注入的 activeConversation.startReview 回调调 review/start（inline，结果回主对话回显）。
struct ReviewTabView: View {
    @Environment(ActiveConversationHolder.self) private var activeConversation
    /// 全量 diff 拉取所需的工作目录（取自选中 thread；缺失则「全量」不可用）。
    var cwd: String?

    @State private var mode: ReviewSourceMode = .turn
    @State private var fullDiff: String?
    @State private var loadingFull = false

    private var turnDiff: String { activeConversation.state?.turnDiff ?? "" }
    private var source: ReviewDiffSource {
        ReviewDiffSource.resolve(mode: mode, turnDiff: turnDiff, fullDiff: fullDiff)
    }

    /// 当前数据源能否发起审查：回调已接线 + 对应数据源有效。
    private var canStartReview: Bool {
        guard activeConversation.startReview != nil else { return false }
        switch mode {
        case .turn: return !turnDiff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .full: return cwd != nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("review.source", selection: $mode) {
                    ForEach(ReviewSourceMode.allCases) { m in Text(m.label).tag(m) }
                }
                .pickerStyle(.segmented)

                // startReview 是 fire-and-forget（设计 D4）：内部 Task 发出 review/start 后立即返回，
                // 不 await 网络往返。因此不设 isStarting 防抖态——它无法覆盖请求生命周期（await 微秒即返回），
                // 只会是形同虚设的假防抖。快速连点最多触发多次 review/start，属 D4 已接受的低危行为。
                Button {
                    Task { _ = await activeConversation.startReview?(mode) }
                } label: {
                    Image(systemName: "sparkle.magnifyingglass")
                }
                .buttonStyle(.plain)
                .disabled(!canStartReview)
                .accessibilityLabel(Text("review.start"))
            }
            .padding(8)

            if loadingFull {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ReviewPanelView(source: source)
            }
        }
        // 切到「全量」且尚未拉取时，经注入的回调按 cwd 拉一次并缓存。
        .task(id: mode) {
            guard mode == .full, fullDiff == nil, let cwd,
                  let fetch = activeConversation.fetchFullDiff else { return }
            loadingFull = true
            fullDiff = await fetch(cwd)
            loadingFull = false
        }
    }
}
