import SwiftUI

/// 下边栏（design D4）：顶部可拖把手（调高，clamp 到最小高）+ 交互式终端。
/// 高度由父级持有并绑定进来；拖动时改 height。
struct BottomPanelView: View {
    @Binding var height: CGFloat
    @Environment(TerminalSession.self) private var terminal
    @Environment(ConnectionStore.self) private var connection
    var cwd: String? = nil
    @State private var hovering = false
    @State private var dragging = false

    /// hover 或拖动中都算「激活」→ 把手变橙加粗（与右栏把手一致；触摸靠「拖动中变橙」反馈）。
    private var active: Bool { hovering || dragging }

    var body: some View {
        VStack(spacing: 0) {
            dragHandle
            SwiftTermView(session: terminal)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: height)
        .task(id: TerminalKey(ready: connection.phase == .ready, cwd: cwd)) {
            // cwd 真跟随：连接就绪 + 会话 cwd 变化时(re)绑定并起 shell。
            guard connection.phase == .ready, let rpc = connection.rpc else { return }
            await terminal.attach(rpc: rpc)
            terminal.startIfNeeded(cwd: cwd)
        }
        .onChange(of: connection.phase) { _, ph in
            if ph == .reconnecting { terminal.handleDisconnect() }
        }
    }

    /// .task id：连接就绪态 + cwd 组合，cwd 变化时重触发（切会话跟随）。
    private struct TerminalKey: Equatable { let ready: Bool; let cwd: String? }

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
