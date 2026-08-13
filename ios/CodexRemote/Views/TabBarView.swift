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
    /// 待移除的机器 id（非空即弹二次确认 confirmationDialog）。
    @State private var removeTarget: UUID?
    @State private var removeFailure: (id: UUID, threadIDs: [String])?
    @State private var removingMachineID: UUID?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(sessions.machineStore.machines) { m in
                        tab(m).id(m.id)
                    }
                    addButton
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            // #7：活动 session 变化 → 把活动 tab 居中滚入（事件驱动，无定时器）。
            .onChange(of: sessions.activeSessionId) { _, newId in
                guard let newId else { return }
                proxy.scrollTo(newId, anchor: .center)
            }
            .onAppear {
                guard let activeId = sessions.activeSessionId else { return }
                Task { @MainActor in
                    await Task.yield()
                    proxy.scrollTo(activeId, anchor: .center)
                }
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
            // 移除机器二次确认（D6）：破坏性操作不由单次点击直接执行，绑定 removeTarget。
            .confirmationDialog("tab.remove.confirm.title",
                                isPresented: removeConfirmBinding,
                                titleVisibility: .visible) {
                Button("tab.remove.confirm.action", role: .destructive) {
                    if let id = removeTarget { removeMachine(id) }
                    removeTarget = nil
                }
                Button("common.cancel", role: .cancel) { removeTarget = nil }
            } message: {
                Text(String.localizedStringWithFormat(
                    L10n.string("tab.remove.confirm.message %@", locale: LocaleManager.currentLocale),
                    removeTarget.flatMap { id in sessions.machineStore.machines.first(where: { $0.id == id })?.displayName } ?? ""
                ))
            }
            .alert("operation.failed.title", isPresented: Binding(
                get: { removeFailure != nil }, set: { if !$0 { removeFailure = nil } }
            )) {
                Button("sidebar.retry") {
                    guard let failure = removeFailure else { return }
                    removeFailure = nil
                    removeMachine(failure.id)
                }
                Button("common.cancel", role: .cancel) { removeFailure = nil }
            } message: {
                Text(cleanupFailureMessage(removeFailure?.threadIDs ?? []))
            }
        }
    }

    /// renameTarget(UUID?) ↔ alert 的 isPresented(Bool) 桥接：present 时不改 target，dismiss 时清空。
    private var renameAlertBinding: Binding<Bool> {
        Binding(get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } })
    }

    /// removeTarget(UUID?) ↔ confirmationDialog 的 isPresented(Bool) 桥接：dismiss 时清空。
    private var removeConfirmBinding: Binding<Bool> {
        Binding(get: { removeTarget != nil },
                set: { if !$0 { removeTarget = nil } })
    }

    private func removeMachine(_ id: UUID) {
        guard removingMachineID == nil else { return }
        removingMachineID = id
        Task {
            let result = await sessions.removeMachine(id: id)
            removingMachineID = nil
            if case .interruptFailed(let ids) = result {
                removeFailure = (id, ids)
            }
        }
    }

    private func cleanupFailureMessage(_ ids: [String]) -> String {
        String.localizedStringWithFormat(
            L10n.string("sideChat.cleanupFailed %@", locale: LocaleManager.currentLocale),
            ids.joined(separator: ", ")
        )
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
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(removingMachineID != nil)
            .accessibilityValue(Text(indicator.accessibilityKey))
            .accessibilityAddTraits(active ? [.isSelected] : [])

            // 可见管理入口（⋯）：触控/指针点击、外接键盘聚焦后回车/空格均可激活；不依赖长按。
            // 命中区 ≥44pt（UI 适配基线）：padding 撑起热区 + contentShape 让留白也可点。
            Menu {
                if sessions.canConnect(id: m.id) {
                    Button("tab.connect", systemImage: "bolt.horizontal") { sessions.connectMachine(id: m.id) }
                } else {
                    Button("tab.disconnect", systemImage: "wifi.slash") { sessions.disconnect(id: m.id) }
                }
                Button("tab.rename", systemImage: "pencil") { beginRename(m) }
                Button("tab.remove", systemImage: "trash", role: .destructive) { removeTarget = m.id }
            } label: {
                Image(systemName: "ellipsis")
                    .padding(.leading, 4).padding(.trailing, 12).padding(.vertical, 8)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(removingMachineID != nil)
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
        .disabled(removingMachineID != nil)
        .minimumHitTarget44()
    }
}

/// tab 圆点：TabIndicator → 颜色映射（none→无/clear，unread→蓝，running→绿，attention→橙，error→红）；
/// attention/error（isBlinking）短暂脉冲后转常亮，避免等待态长期占用合成资源。
struct DotView: View {
    let indicator: TabIndicator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    private struct PulseKey: Equatable {
        let indicator: TabIndicator
        let reduceMotion: Bool
    }

    var body: some View {
        Group {
            if let symbolName = indicator.symbolName {
                Image(systemName: symbolName)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(color)
                    .frame(width: 12, height: 12)
            } else {
                Color.clear.frame(width: 12, height: 12)
            }
        }
        .opacity(indicator.shouldAnimate(reduceMotion: reduceMotion) && dim ? 0.25 : 1)
        .animation(.easeInOut(duration: 0.7), value: dim)
        .task(id: PulseKey(indicator: indicator, reduceMotion: reduceMotion)) {
            dim = false
            guard indicator.shouldAnimate(reduceMotion: reduceMotion) else { return }
            // Draw attention briefly, then stay visible without a permanent compositor animation.
            for _ in 0..<4 {
                guard !Task.isCancelled else { return }
                dim.toggle()
                try? await Task.sleep(for: .milliseconds(700))
            }
            dim = false
        }
        .accessibilityHidden(true)
    }

    private var color: Color {
        switch indicator {
        case .none: .clear
        case .unread: .blue
        case .running: .green
        case .attention: .orange
        case .error: .red
        case .disconnected: .gray
        }
    }
}
