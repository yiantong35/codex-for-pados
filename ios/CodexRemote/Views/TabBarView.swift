import SwiftUI

/// 横向滚动 tab 栏（多机器切换主入口）。窄屏放不下就横滑；每机器一个 tab（显示名 + 圆点 + ⋯ 菜单），
/// ⋯ 菜单弹管理项（连接/断开/移除，可见入口、不依赖长按），末尾 [+] 添加机器。圆点数据源为 T6 的 TabIndicator。
struct TabBarView: View {
    @Environment(SessionsManager.self) private var sessions
    @State private var showCapAlert = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(sessions.machineStore.machines) { m in
                    tab(m)
                }
                addButton
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(.bar)
        .alert("tab.capReached", isPresented: $showCapAlert) {
            Button("common.ok", role: .cancel) {}
        }
    }

    @ViewBuilder private func tab(_ m: MachineConfig) -> some View {
        let active = sessions.activeSessionId == m.id
        let indicator = sessions.indicator(for: m.id)
        HStack(spacing: 6) {
            // tab 切换主体：仅此 Button 触发切换，命中区不含 ⋯ 菜单。
            Button { sessions.setActive(m.id) } label: {
                HStack(spacing: 6) {
                    Text(m.displayName).lineLimit(1)
                        .foregroundStyle(active ? Color.accentColor : Color.primary)
                    DotView(indicator: indicator)
                }
            }
            .buttonStyle(.plain)

            // 可见管理入口（⋯）：触控/指针点击、外接键盘聚焦后回车/空格均可激活；不依赖长按。
            Menu {
                if sessions.canConnect(id: m.id) {
                    Button("tab.connect", systemImage: "bolt.horizontal") { sessions.connectMachine(id: m.id) }
                }
                Button("tab.disconnect", systemImage: "wifi.slash") { sessions.disconnect(id: m.id) }
                Button("tab.remove", systemImage: "trash", role: .destructive) { sessions.removeMachine(id: m.id) }
            } label: {
                Image(systemName: "ellipsis")
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(active ? Color.accentColor.opacity(0.12) : Color.clear, in: Capsule())
    }

    @ViewBuilder private var addButton: some View {
        Button {
            if sessions.machineStore.canAddMore { sessions.presentAddMachine() }
            else { showCapAlert = true }
        } label: {
            Image(systemName: "plus")
                .padding(.horizontal, 10).padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }
}

/// tab 圆点：TabIndicator → 颜色映射（none→无/clear，unread→蓝，running→绿，attention→橙，error→红）；
/// attention/error（isBlinking）在 opacity 1↔0.25 间做 easeInOut 无限往复闪烁。
struct DotView: View {
    let indicator: TabIndicator
    @State private var dim = false

    var body: some View {
        Group {
            switch indicator {
            case .none: Color.clear.frame(width: 8, height: 8)
            case .unread: dot(.blue)
            case .running: dot(.green)
            case .attention: dot(.orange)
            case .error: dot(.red)
            }
        }
        .opacity(indicator.isBlinking && dim ? 0.25 : 1)
        .animation(indicator.isBlinking ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true) : .default,
                   value: dim)
        // 由 indicator 变化驱动闪烁，而非仅靠 onAppear：视图未重建但 indicator 从非闪烁跃迁到
        // .attention/.error（T11 接真实数据后同一 tab 内状态跃迁）时也能正确启停。
        .onChange(of: indicator.isBlinking) { _, blinking in dim = blinking }
        .onAppear { dim = indicator.isBlinking }
    }

    private func dot(_ c: Color) -> some View { Circle().fill(c).frame(width: 8, height: 8) }
}
