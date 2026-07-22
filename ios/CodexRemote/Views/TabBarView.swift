import SwiftUI

/// 横向滚动 tab 栏（多机器切换主入口）。窄屏放不下就横滑；每机器一个 tab（圆点 + 显示名 + ⋯ 菜单），
/// ⋯ 菜单弹管理项（连接/断开/重命名/移除，可见入口、不依赖长按），末尾 [+] 添加机器。圆点数据源为 T6 的 TabIndicator。
struct TabBarView: View {
    @Environment(SessionsManager.self) private var sessions
    @State private var showCapAlert = false
    /// 待重命名的机器 id（非空即弹重命名 alert）。
    @State private var renameTarget: UUID?
    /// 重命名 alert 的输入草稿。
    @State private var renameDraft = ""

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
        // 重命名 alert：绑定到 renameTarget（非空即present）；确认写回 SessionsManager.rename。
        .alert("tab.rename.title", isPresented: renameAlertBinding) {
            TextField("tab.rename.placeholder", text: $renameDraft)
            Button("common.cancel", role: .cancel) { renameTarget = nil }
            Button("tab.rename.confirm") {
                if let id = renameTarget { sessions.rename(id: id, to: renameDraft) }
                renameTarget = nil
            }
        }
    }

    /// renameTarget(UUID?) ↔ alert 的 isPresented(Bool) 桥接：present 时不改 target，dismiss 时清空。
    private var renameAlertBinding: Binding<Bool> {
        Binding(get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } })
    }

    @ViewBuilder private func tab(_ m: MachineConfig) -> some View {
        let active = sessions.activeSessionId == m.id
        let indicator = sessions.indicator(for: m.id)
        HStack(spacing: 0) {
            // tab 切换主体：仅此 Button 触发切换，命中区不含 ⋯ 菜单。
            // 内边距放进 label 并配 contentShape，使圆点/文字周围留白也可点切换（避免死区）。
            Button { sessions.setActive(m.id) } label: {
                HStack(spacing: 6) {
                    DotView(indicator: indicator)
                        // 圆点按文字「大写字母光学中心」对齐：HStack 默认按 frame 中心对齐，
                        // 但全大写文字（如 MM）无降部，字形光学中心高于 frame 中心 → 圆点显得偏低。
                        // 用 alignmentGuide 把圆点的 center 判定点下移 2pt，使其相对行中心上移、贴合字形。
                        .alignmentGuide(VerticalAlignment.center) { d in d[VerticalAlignment.center] + 2 }
                    Text(m.displayName).lineLimit(1)
                        .foregroundStyle(active ? Color.accentColor : Color.primary)
                }
                .padding(.leading, 12).padding(.trailing, 4).padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // 可见管理入口（⋯）：触控/指针点击、外接键盘聚焦后回车/空格均可激活；不依赖长按。
            // 命中区 ≥44pt（UI 适配基线）：padding 撑起热区 + contentShape 让留白也可点。
            Menu {
                if sessions.canConnect(id: m.id) {
                    Button("tab.connect", systemImage: "bolt.horizontal") { sessions.connectMachine(id: m.id) }
                }
                Button("tab.disconnect", systemImage: "wifi.slash") { sessions.disconnect(id: m.id) }
                Button("tab.rename", systemImage: "pencil") { beginRename(m) }
                Button("tab.remove", systemImage: "trash", role: .destructive) { sessions.removeMachine(id: m.id) }
            } label: {
                Image(systemName: "ellipsis")
                    .padding(.leading, 4).padding(.trailing, 12).padding(.vertical, 8)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(active ? Color.accentColor.opacity(0.12) : Color.clear, in: Capsule())
    }

    /// 进入重命名态：预填当前显示名并弹 alert。
    private func beginRename(_ m: MachineConfig) {
        renameDraft = m.displayName
        renameTarget = m.id
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
