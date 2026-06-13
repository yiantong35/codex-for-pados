import SwiftUI

/// 面板间的竖向可拖把手（design D3：右栏可拖改宽 + 「可拖提示」）。
///
/// 取代 `.inspector` 内建 resize——后者在 NavigationSplitView 三栏全开时不可靠
/// （左栏开着时右栏拖不动）。这里自绘把手 + DragGesture，行为不受栏数影响。
///
/// 「可拖提示」：常驻一条细把手 = 视觉上「这里能拖」（纯触摸也看得到）；
/// 指针 hover（触控板）时把手加粗并高亮为主题色，配合 `.hoverEffect`。
///
/// 拖动逻辑（基准宽 + 位移）由父级用 `WorkspaceMetrics.resizedRightWidth` 计算，
/// 本视图只透传手势的水平位移与手势结束事件，便于纯函数单测。
struct PanelResizeHandle: View {
    /// 拖动中：传出本次手势相对起点的水平位移（translation.width）。
    var onChanged: (CGFloat) -> Void
    /// 手势结束：父级据此清空基准宽。
    var onEnded: () -> Void

    @State private var hovering = false

    var body: some View {
        ZStack {
            Rectangle().fill(.bar)
            Divider()
            Capsule()
                .fill(hovering ? Color.accentColor : Color.secondary.opacity(0.55))
                .frame(width: hovering ? 5 : 3, height: 44)
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
        .frame(width: 10)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .hoverEffect(.highlight)
        .onHover { hovering = $0 }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { onChanged($0.translation.width) }
                .onEnded { _ in onEnded() }
        )
        .accessibilityIdentifier("rightPanelResizeHandle")
        .accessibilityLabel(Text("workspace.rightPanel.toggle"))
    }
}
