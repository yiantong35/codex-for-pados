import SwiftUI

/// 右边栏（design D3）：审查面板。占位升级为纯 diff 查看器（UnifiedDiffParser + 文件树 + 逐行红绿）。
/// 顶部数据源切换：本轮（当前 turn 的 turnDiff，现成）/ 全量（gitDiffToRemote 拉取的仓库全量 diff）。
struct RightPanelView: View {
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
