import SwiftUI

/// 下边栏（design D4）：顶部可拖把手（调高，clamp 到最小高）+ 占位空态。
/// 高度由父级持有并绑定进来；拖动时改 height。
struct BottomPanelView: View {
    @Binding var height: CGFloat
    @State private var hovering = false
    @State private var dragging = false

    /// hover 或拖动中都算「激活」→ 把手变橙加粗（与右栏把手一致；触摸靠「拖动中变橙」反馈）。
    private var active: Bool { hovering || dragging }

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
        ZStack(alignment: .top) {
            Rectangle().fill(.bar)
            Capsule()
                .fill(active ? Color.accentColor : Color.secondary.opacity(0.55))
                .frame(width: WorkspaceMetrics.bottomResizeHandleWidth,
                       height: active
                       ? WorkspaceMetrics.bottomResizeHandleActiveHeight
                       : WorkspaceMetrics.bottomResizeHandleInactiveHeight)
                .padding(.top, WorkspaceMetrics.bottomResizeHandleTopPadding)
        }
        .frame(height: WorkspaceMetrics.bottomResizeHandleTrackHeight)
        .contentShape(Rectangle())
        .hoverEffect(.highlight)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: active)
        .gesture(
            DragGesture()
                .onChanged { value in
                    dragging = true
                    // 向上拖（dy<0）增高；clamp 到 [min, 屏高的合理上界]。
                    let proposed = height - value.translation.height
                    height = WorkspaceMetrics.clamp(proposed,
                                                    min: WorkspaceMetrics.bottomPanelMinHeight,
                                                    max: 900)
                }
                .onEnded { _ in dragging = false }
        )
        .accessibilityLabel(Text("workspace.bottomPanel.toggle"))
    }
}
