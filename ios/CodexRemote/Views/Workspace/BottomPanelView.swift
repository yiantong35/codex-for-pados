import SwiftUI

/// 下边栏（design D4）：顶部可拖把手（调高，clamp 到最小高）+ 交互式终端。
/// 高度由父级持有并绑定进来；拖动时改 height。
struct BottomPanelView: View {
    @Binding var height: CGFloat
    var maximumHeight: CGFloat = 900
    @Environment(TerminalSession.self) private var terminal
    @Environment(ConnectionStore.self) private var connection
    @Environment(ClipboardPolicyStore.self) private var clipboardPolicy
    var cwd: String? = nil
    @State private var hovering = false
    @State private var dragging = false
    @State private var dragStartHeight: CGFloat?

    /// hover 或拖动中都算「激活」→ 把手变橙加粗（与右栏把手一致；触摸靠「拖动中变橙」反馈）。
    private var active: Bool { hovering || dragging }

    var body: some View {
        VStack(spacing: 0) {
            dragHandle
            SwiftTermView(session: terminal, clipboardPolicy: clipboardPolicy)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: height)
        .onChange(of: maximumHeight, initial: true) { _, newMaximum in
            height = WorkspaceMetrics.clamp(
                height,
                min: WorkspaceMetrics.bottomPanelMinHeight,
                max: newMaximum
            )
        }
        .task(id: TerminalKey(ready: connection.phase == .ready, cwd: cwd)) {
            // cwd 真跟随：连接就绪 + 会话 cwd 变化时(re)绑定并起 shell。
            guard connection.phase == .ready, let rpc = connection.rpc else { return }
            await terminal.attach(rpc: rpc)
            terminal.startIfNeeded(cwd: cwd)
        }
        .onChange(of: connection.phase) { _, ph in
            switch ph {
            case .reconnecting: terminal.handleReconnecting()
            case .ready: terminal.handleReconnectSucceeded()
            case .failed, .disconnected: terminal.handleReconnectFailed()
            case .connecting, .initializing: break
            }
        }
    }

    /// .task id：连接就绪态 + cwd 组合，cwd 变化时重触发（切会话跟随）。
    private struct TerminalKey: Equatable { let ready: Bool; let cwd: String? }

    /// 可拖把手：纵向拖动改高，松手 clamp 到 [min, max]。
    /// 拖动效果（手势）靠模拟器/UI 测试确认；clamp 逻辑已在 WorkspaceMetricsTests 单测。
    private var dragHandle: some View {
        ZStack {
            // 透明轨道撑满命中区，配合下方 .contentShape 保证透明区仍可命中 DragGesture。
            Color.clear
            // 顶部 1pt 主题橙分界线：与竖直列分隔线（accentColor）统一，标出下栏与上方列的分界。
            Rectangle().fill(Color.accentColor).frame(height: 1)
                .frame(maxHeight: .infinity, alignment: .top)
            Capsule()
                .fill(active ? Color.accentColor : Color.secondary.opacity(0.55))
                .frame(width: active ? 42 : 36, height: active ? 5 : 3)
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
                    if dragStartHeight == nil { dragStartHeight = height }
                    height = WorkspaceMetrics.draggedBottomHeight(
                        start: dragStartHeight ?? height,
                        translation: value.translation.height,
                        maximumHeight: maximumHeight)
                }
                .onEnded { _ in
                    dragging = false
                    dragStartHeight = nil
                }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("workspace.bottomPanel.resize"))
        .accessibilityValue(Text("workspace.bottomPanel.height \(Int(height))"))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                height = WorkspaceMetrics.adjustedBottomHeight(
                    height, increment: true, maximumHeight: maximumHeight)
            case .decrement:
                height = WorkspaceMetrics.adjustedBottomHeight(
                    height, increment: false, maximumHeight: maximumHeight)
            @unknown default: break
            }
        }
    }
}
