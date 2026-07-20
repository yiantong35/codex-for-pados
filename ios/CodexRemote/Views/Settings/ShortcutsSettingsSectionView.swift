import SwiftUI

/// 快捷键分区（ipad-settings-page D2 + ipad-keyboard-shortcuts 自定义需求）：
/// 按作用域分组列出全部动作 + 当前键位；可自定义动作提供「改键」（onKeyPress 捕获实键 → 校验管线）
/// 与「恢复默认」；固定动作（Esc 取消）只读、无改键入口。
struct ShortcutsSettingsSectionView: View {
    @Environment(ShortcutStore.self) private var shortcuts

    /// 当前处于录入态的动作（onKeyPress 仅在此动作行挂载，退出即卸载——功耗约束 1）。
    @State private var recordingAction: ShortcutAction?
    /// 最近一次改键被拒原因（inline 回显）。
    @State private var rejection: RebindRejection?
    @FocusState private var recordingFocused: Bool

    var body: some View {
        List {
            ForEach(scopeGroups, id: \.id) { group in
                Section(group.title) {
                    ForEach(group.actions) { action in
                        row(action)
                    }
                }
            }
            Section {
                Button("shortcut.resetAll", role: .destructive) {
                    shortcuts.resetAll()
                    exitRecording()
                }
            }
        }
        .navigationTitle("settings.shortcuts")
    }

    /// 分组：全局 / 主界面 / 表单（顺序固定）。
    /// `id` 用稳定 String（LocalizedStringKey 不符合 Hashable，无法直接作 ForEach id）。
    private var scopeGroups: [(id: String, title: LocalizedStringKey, actions: [ShortcutAction])] {
        [
            ("global",    "shortcut.scope.global",    ShortcutAction.allCases.filter { $0.scope == .global }),
            ("workspace", "shortcut.scope.workspace", ShortcutAction.allCases.filter { $0.scope == .workspace }),
            ("form",      "shortcut.scope.form",      ShortcutAction.allCases.filter { $0.scope == .form }),
        ]
    }

    @ViewBuilder
    private func row(_ action: ShortcutAction) -> some View {
        let isRecording = recordingAction == action
        HStack {
            Text(action.titleKey).foregroundStyle(.primary)
            Spacer()
            if isRecording {
                Text("shortcut.recording")
                    .font(.caption).foregroundStyle(Color.accentColor)
            } else {
                Text(shortcuts.combo(for: action).displayString)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if action.isCustomizable {
                Button(isRecording ? "common.cancel" : "shortcut.rebind") {
                    if isRecording { exitRecording() } else { enterRecording(action) }
                }
                .buttonStyle(.borderless)
                if shortcuts.isOverridden(action) {
                    Button("shortcut.resetDefault") {
                        shortcuts.resetToDefault(action)
                    }
                    .buttonStyle(.borderless)
                }
            } else {
                Text("shortcut.fixed").font(.caption).foregroundStyle(.secondary)
            }
        }
        // 录入态回显被拒原因。
        .overlay(alignment: .bottomLeading) {
            if isRecording, let rejection {
                Text(rejectionMessage(rejection))
                    .font(.caption2).foregroundStyle(.red)
            }
        }
        // onKeyPress 只在录入行挂载（功耗约束 1）：捕获实键 → 校验管线。
        .focusable(isRecording)
        .focused($recordingFocused)
        .keyCapture(active: isRecording) { press in handleKeyPress(press, for: action) }
    }

    private func enterRecording(_ action: ShortcutAction) {
        rejection = nil
        recordingAction = action
        recordingFocused = true
    }

    private func exitRecording() {
        recordingAction = nil
        rejection = nil
    }

    private func handleKeyPress(_ press: KeyPress, for action: ShortcutAction) -> KeyPress.Result {
        let combo = KeyCombo(keyPress: press)
        switch shortcuts.rebind(action, to: combo) {
        case .accepted:
            exitRecording()
        case .rejected(let reason):
            rejection = reason   // 保持录入态显示原因，原绑定不变
        }
        return .handled
    }

    private func rejectionMessage(_ reason: RebindRejection) -> LocalizedStringKey {
        switch reason {
        case .systemReserved:
            return "shortcut.conflict.systemReserved"
        case .occupied(let occupant):
            // 简化：统一提示「已被占用」（含占用动作可在 Task 13 用 %@ 插值细化）。
            _ = occupant
            return "shortcut.conflict.occupied"
        case .notCustomizable:
            // 固定动作不可改键：正常 UI 不会触发（固定行无改键入口），
            // 兜底复用系统保留提示（本地化 key 由 Task 13 统一收口，此处不新增 key）。
            return "shortcut.conflict.systemReserved"
        }
    }
}

private extension View {
    /// 条件挂载 onKeyPress：仅在 active（录入态）时监听键盘，非录入行不挂载
    /// （功耗约束 1）。目标 SDK 的 `.onKeyPress(action:)` 不接受可选闭包，
    /// 故用 @ViewBuilder 条件分支替代 plan 里传 nil 的写法。
    @ViewBuilder
    func keyCapture(active: Bool, _ action: @escaping (KeyPress) -> KeyPress.Result) -> some View {
        if active {
            self.onKeyPress(action: action)
        } else {
            self
        }
    }
}
