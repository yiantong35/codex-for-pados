import SwiftUI

/// 审查 tab（原 RightPanelView，纯剪切进 tab 容器）：数据源切换（本轮/全量）+ 逐行红绿 diff。
/// 逻辑与容器化之前完全一致，靠 ReviewPanelTests 回归兜底。
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

    var body: some View {
        VStack(spacing: 0) {
            Picker("数据源", selection: $mode) {
                ForEach(ReviewSourceMode.allCases) { m in Text(m.label).tag(m) }
            }
            .pickerStyle(.segmented)
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
