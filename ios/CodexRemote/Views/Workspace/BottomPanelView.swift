import SwiftUI

/// 下边栏（design D4）：顶部可拖把手（调高，clamp 到最小高）+ 占位空态。
/// 高度由父级（detail 区 VStack）持有并绑定进来；拖动时改 height。
struct BottomPanelView: View {
    @Binding var height: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            dragHandle
            PanelEmptyState()
        }
        .frame(height: height)
    }

    /// 可拖把手：纵向拖动改高，松手 clamp 到 [min, max]。
    /// 拖动效果（手势）靠模拟器/UI 测试确认；clamp 逻辑已在 WorkspaceMetricsTests 单测。
    private var dragHandle: some View {
        ZStack {
            Rectangle().fill(.bar).frame(height: 16)
            Capsule().fill(.secondary).frame(width: 40, height: 4)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture()
                .onChanged { value in
                    // 向上拖（dy<0）增高；clamp 到 [min, 屏高的合理上界]。
                    let proposed = height - value.translation.height
                    height = WorkspaceMetrics.clamp(proposed,
                                                    min: WorkspaceMetrics.bottomPanelMinHeight,
                                                    max: 900)
                }
        )
        .accessibilityLabel(Text("workspace.bottomPanel.toggle"))
    }
}
