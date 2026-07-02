import SwiftUI

/// 右边栏（design D3）：审查面板。占位升级为纯 diff 查看器（UnifiedDiffParser + 文件树 + 逐行红绿）。
struct RightPanelView: View {
    @Environment(ActiveConversationHolder.self) private var activeConversation

    var body: some View {
        // 默认数据源=当前会话本轮 diff；⑤变更/进度条跳转接线待各分支合 master 后接(TODO)。
        ReviewPanelView(source: ReviewDiffSource(diff: activeConversation.state?.turnDiff ?? "", label: "本轮", cwd: nil))
    }
}
