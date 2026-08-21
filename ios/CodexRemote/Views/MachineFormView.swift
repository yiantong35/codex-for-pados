import SwiftUI

/// 添加机器表单——当前唯一机器类型是 Relay，因此直接进入配对导入，避免无意义的中间选择页。
/// 呈现方式：sheet（由 `sessions.addMachinePresented` 绑定驱动，见 CodexRemoteApp）。
///
/// 软键盘不遮挡：ScrollView 包裹 + `.scrollDismissesKeyboard(.interactively)`。
/// 外接键盘走标准文本输入（Esc 取消）。
struct MachineFormView: View {
    @Environment(SessionsManager.self) private var sessions
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            RelayPairingImportView(onImported: { dismiss() })
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)   // T11：Esc 取消（固定，spec）
                }
            }
        }
        .onAppear { PairingDiag.log.notice("MachineFormView(host1) onAppear") }
        .onDisappear { PairingDiag.log.notice("MachineFormView(host1) onDisappear") }
    }
}
