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
    /// 值型焦点：绑定到「当前录入行」的动作，支持多行录入互斥、退出即释放（FIX 3）。
    @FocusState private var focusedAction: ShortcutAction?

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
            Text(String(localized: String.LocalizationValue(action.titleStringKey))).foregroundStyle(.primary)
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
                Text(rejectionMessage(rejection))   // 已解析 String（含占用动作名），verbatim 渲染避免二次本地化
                    .font(.caption2).foregroundStyle(.red)
            }
        }
        // onKeyPress 只在录入行挂载（功耗约束 1）：捕获实键 → 校验管线。
        .focusable(isRecording)
        .focused($focusedAction, equals: action)
        .keyCapture(active: isRecording) { press in handleKeyPress(press, for: action) }
    }

    private func enterRecording(_ action: ShortcutAction) {
        rejection = nil
        recordingAction = action
        focusedAction = action
    }

    private func exitRecording() {
        recordingAction = nil
        rejection = nil
        focusedAction = nil
    }

    private func handleKeyPress(_ press: KeyPress, for action: ShortcutAction) -> KeyPress.Result {
        // Esc 拦截由 recordingOutcome 完成：判 .cancelled 而非当作组合键校验，
        // 否则 Esc 归约成 cancelForm 键位、被占用检测判 .occupied 而无法退出（FIX 2）。
        let outcome = shortcuts.recordingOutcome(for: action,
                                                 isEscape: press.key == .escape,
                                                 combo: KeyCombo(keyPress: press))
        switch outcome {
        case .cancelled, .accepted:
            exitRecording()
        case .rejected(let reason):
            rejection = reason   // 保持录入态显示原因，原绑定不变
        }
        return .handled
    }

    /// 被拒提示（已解析为最终 String）。占用冲突插入占用动作的本地化名（FIX 1，spec §冲突检测）。
    private func rejectionMessage(_ reason: RebindRejection) -> String {
        switch reason {
        case .missingRequiredModifier:
            return String(localized: "shortcut.conflict.missingModifier")
        case .systemReserved:
            return String(localized: "shortcut.conflict.systemReserved")
        case .occupied(let occupant):
            let name = String(localized: String.LocalizationValue(occupant.titleStringKey))
            // key「shortcut.conflict.occupied」的本地化值为 "已被「%@」占用" / "Already used by \"%@\""；
            // defaultValue 既是开发语言源串、又携带插值实参（name）填入该格式串的 %@。
            return String(localized: "shortcut.conflict.occupied", defaultValue: "Already used by \"\(name)\"")
        case .notCustomizable:
            // unreachable via UI（固定行不暴露改键入口）；仅防御性兜底，release 不崩。
            assertionFailure("notCustomizable rejection should be unreachable from the shortcuts UI")
            return String(localized: "shortcut.conflict.systemReserved")
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
