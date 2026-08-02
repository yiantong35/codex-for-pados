import SwiftUI

/// 添加机器表单——纯 relay 配对入口：经 NavigationLink 进
/// RelayPairingImportView 粘贴/扫码导入；成功后由该界面自行 dismiss。
/// 呈现方式：sheet（由 `sessions.addMachinePresented` 绑定驱动，见 CodexRemoteApp）。
///
/// 软键盘不遮挡：ScrollView 包裹 + `.scrollDismissesKeyboard(.interactively)`。
/// 外接键盘走标准文本输入（Esc 取消）。
struct MachineFormView: View {
    @Environment(SessionsManager.self) private var sessions
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        relayEntry
                            .frame(maxWidth: 480)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(24)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("machineForm.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)   // T11：Esc 取消（固定，spec）
                }
            }
        }
    }

    /// relay 配对入口：卡片内说明 + NavigationLink 进粘贴导入界面。
    private var relayEntry: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("relayImport.hint")
                .font(.footnote)
                .foregroundStyle(.secondary)
            NavigationLink {
                RelayPairingImportView()
            } label: {
                Label("relayImport.title", systemImage: "qrcode.viewfinder")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(.tertiarySystemGroupedBackground))
            )
        }
        .padding(28)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 16, x: 0, y: 6)
    }
}
