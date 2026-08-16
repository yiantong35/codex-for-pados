import SwiftUI

/// 原生 toolbar 机器菜单。机器切换和当前机器管理集中在一个系统入口，避免额外占用一行工作区高度。
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
        Menu {
            Section("tab.machine.section") {
                ForEach(sessions.machineStore.machines) { machine in
                    Button {
                        sessions.setActive(machine.id)
                    } label: {
                        HStack {
                            Label(machine.displayName, systemImage: menuSymbol(for: machine))
                            if sessions.activeSessionId == machine.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .disabled(removingMachineID == machine.id)
                    .accessibilityValue(Text(sessions.indicator(for: machine.id).accessibilityKey))
                }
            }

            if let machine = activeMachine {
                Section(machine.displayName) {
                    if sessions.canConnect(id: machine.id) {
                        Button("tab.connect", systemImage: "bolt.horizontal") {
                            sessions.connectMachine(id: machine.id)
                        }
                    } else {
                        Button("tab.disconnect", systemImage: "wifi.slash") {
                            sessions.disconnect(id: machine.id)
                        }
                    }
                    Button("tab.rename", systemImage: "pencil") { beginRename(machine) }
                    Button("tab.remove", systemImage: "trash", role: .destructive) {
                        removeTarget = machine.id
                    }
                }
                .disabled(removingMachineID == machine.id)
            }

            Section {
                Button("tab.add", systemImage: "plus") {
                    if sessions.machineStore.canAddMore { sessions.presentAddMachine() }
                    else { showCapAlert = true }
                }
            }
        } label: {
            HStack(spacing: 6) {
                if let machine = activeMachine {
                    if removingMachineID == machine.id {
                        ProgressView().controlSize(.small).frame(width: 12, height: 12)
                    } else {
                        DotView(indicator: sessions.indicator(for: machine.id))
                    }
                    Text(machine.displayName).lineLimit(1)
                } else {
                    Image(systemName: "desktopcomputer")
                    Text("tab.machine.none")
                }
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(minHeight: 44)
        }
        .accessibilityLabel(Text("tab.machine.switcher"))
        .accessibilityValue(activeMachine.map {
            Text("\($0.displayName), \(L10n.string(sessions.indicator(for: $0.id).accessibilityKeyString, locale: LocaleManager.currentLocale))")
        } ?? Text("tab.machine.none"))
        .alert("tab.capReached", isPresented: $showCapAlert) {
            Button("common.ok", role: .cancel) {}
        }
        .alert("tab.rename.title", isPresented: renameAlertBinding) {
            TextField("tab.rename.placeholder", text: $renameDraft)
            Button("common.cancel", role: .cancel) { renameTarget = nil }
            Button("tab.rename.confirm") {
                if let id = renameTarget { sessions.rename(id: id, to: renameDraft) }
                renameTarget = nil
            }
        }
        .confirmationDialog("tab.remove.confirm.title", isPresented: removeConfirmBinding,
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

    private var activeMachine: MachineConfig? {
        guard let id = sessions.activeSessionId else { return nil }
        return sessions.machineStore.machines.first { $0.id == id }
    }

    private func menuSymbol(for machine: MachineConfig) -> String {
        if sessions.activeSessionId == machine.id { return "checkmark.circle.fill" }
        return sessions.indicator(for: machine.id).symbolName ?? "circle"
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

    /// 进入重命名态：预填当前显示名并弹 alert。
    private func beginRename(_ m: MachineConfig) {
        renameDraft = m.displayName
        renameTarget = m.id
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
