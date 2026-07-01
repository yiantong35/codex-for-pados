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
    @State private var input = ""

    /// hover 或拖动中都算「激活」→ 把手变橙加粗（与右栏把手一致；触摸靠「拖动中变橙」反馈）。
    private var active: Bool { hovering || dragging }

    var body: some View {
        VStack(spacing: 0) {
            dragHandle
            terminalArea
            terminalInput
        }
        .frame(height: height)
        .task(id: connection.phase) {
            guard connection.phase == .ready, let rpc = connection.rpc else { return }
            await terminal.attach(rpc: rpc)
            if terminal.processId == nil { terminal.start(cwd: cwd) }
        }
        .onChange(of: connection.phase) { _, ph in
            if ph == .reconnecting { terminal.handleDisconnect() }
        }
    }

    // MARK: - 终端输出区（滚动 + 右侧固定 gutter 常驻滚动条）

    private var terminalArea: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(Self.attributed(terminal.runs))
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .id("bottomAnchor")
                }
                .scrollIndicators(.hidden)   // 隐藏系统悬浮 indicator，右侧自绘常驻滚动条
                .onChange(of: terminal.runs.count) { _, _ in
                    withAnimation(.linear(duration: 0.1)) { proxy.scrollTo("bottomAnchor", anchor: .bottom) }
                }
            }
            residentScrollbar   // 固定 gutter：宽度恒定，布局不跳、cols 稳定
        }
        .frame(maxHeight: .infinity)
    }

    /// 固定宽度 gutter + 自绘常驻滚动指示器（始终占位，不挤内容宽度）。
    private var residentScrollbar: some View {
        GeometryReader { geo in
            let trackH = geo.size.height
            Capsule()
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 4, height: max(24, trackH * 0.25))
                .position(x: 4, y: trackH * 0.875)   // 追加式滚动：指示器常驻底部区
        }
        .frame(width: 8)
    }

    private var terminalInput: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            TextField("terminal.input.placeholder", text: $input)
                .font(.system(.caption, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit {
                    guard !input.isEmpty else { return }
                    terminal.sendInput(input + "\n")
                    input = ""
                }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(.bar)
    }

    private static func attributed(_ runs: [ANSIParser.Run]) -> AttributedString {
        var out = AttributedString()
        for r in runs {
            var frag = AttributedString(r.text)
            if let c = r.color { frag.foregroundColor = c }
            if r.bold { frag.font = .system(.caption, design: .monospaced).bold() }
            out += frag
        }
        return out
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
