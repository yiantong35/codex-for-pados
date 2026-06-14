import SwiftUI

/// 右栏左缘的竖向可拖把手（design D3：右栏可拖改宽 + 「可拖提示」）。
///
/// 取代 `.inspector` 内建 resize——后者在 NavigationSplitView 三栏全开时不可靠。
/// 这里自绘把手 + DragGesture，行为不受栏数影响。
///
/// 拖动策略（消闪）：父级**松手才提交**最终宽度（横向 resize 会逼对话区每帧重折行 →
/// 闪屏）。拖动中只透传位移给父级画跟手的预览导引线，松手才落最终宽。
///
/// 「可拖提示」：常驻一条细把手 = 视觉上「这里能拖」（纯触摸也看得到）；
/// **hover（触控板指针）或正在拖动**时把手加粗并高亮为主题橙——触摸没有 hover，
/// 故用「拖动中变橙」给触摸场景反馈。
struct PanelResizeHandle: View {
    /// 拖动中：传出本次手势相对起点的水平位移（translation.width）。
    var onChanged: (CGFloat) -> Void
    /// 手势结束：父级据此提交最终宽度。
    var onEnded: () -> Void

    @State private var hovering = false
    @State private var dragging = false

    /// hover 或拖动中都算「激活」→ 变橙加粗。
    private var active: Bool { hovering || dragging }

    var body: some View {
        ZStack {
            Rectangle().fill(.bar)
            Divider()
            Capsule()
                .fill(active ? Color.accentColor : Color.secondary.opacity(0.55))
                .frame(width: active ? 5 : 3, height: 44)
                .animation(.easeOut(duration: 0.12), value: active)
        }
        .frame(width: 10)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .hoverEffect(.highlight)
        .onHover { hovering = $0 }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { dragging = true; onChanged($0.translation.width) }
                .onEnded { _ in dragging = false; onEnded() }
        )
        .accessibilityIdentifier("rightPanelResizeHandle")
        .accessibilityLabel(Text("workspace.rightPanel.toggle"))
    }
}
