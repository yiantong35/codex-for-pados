import SwiftUI

/// 添加机器表单：复用 ConnectionConfigView 的卡片 UI（字段 + 公钥块），
/// 填完调 `sessions.addMachineAndConnect(_:)` → 自动切过去并连接（D13），成功后 dismiss。
/// 呈现方式：sheet（由 `sessions.addMachinePresented` 绑定驱动，见 CodexRemoteApp）。
///
/// 软键盘不遮挡：ScrollView 包裹 + `.scrollDismissesKeyboard(.interactively)`。
/// 外接键盘走标准文本输入（Tab/Esc），本轮不做自定义快捷键。
struct MachineFormView: View {
    @Environment(SessionsManager.self) private var sessions
    @Environment(\.dismiss) private var dismiss

    @State private var displayName = ""
    @State private var host = ""
    @State private var user = ""
    @State private var sshPort = "22"
    /// 本机 KeyManager：进入即生成（幂等），展示公钥供复制。
    @State private var keyManager = KeyManager()
    @State private var copied = false

    /// 可保存判定（纯函数，便于单测）：host/user trim 后非空，且未达上限（双保险，TabBar 已拦一层）。
    static func canSave(host: String, user: String, canAddMore: Bool) -> Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty
            && !user.trimmingCharacters(in: .whitespaces).isEmpty
            && canAddMore
    }

    private var canSave: Bool {
        Self.canSave(host: host, user: user, canAddMore: sessions.machineStore.canAddMore)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()

                ScrollView {
                    card
                        .frame(maxWidth: 480)
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
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("machineForm.save") { save() }
                        .disabled(!canSave)
                }
            }
        }
        // 进入即确保本机密钥存在（幂等），保证公钥可展示、连接前置满足。
        .onAppear { keyManager.generateIfNeeded() }
    }

    /// 居中卡片：字段（显示名/host/user/端口）+ 公钥块。
    private var card: some View {
        VStack(spacing: 20) {
            VStack(spacing: 14) {
                field {
                    TextField("machineForm.displayName", text: $displayName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                field {
                    TextField("conn.host", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                field {
                    TextField("machineForm.user", text: $user)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                field {
                    TextField("machineForm.sshPort", text: $sshPort)
                        .keyboardType(.numberPad)
                }
            }

            publicKeyBlock
        }
        .padding(28)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 16, x: 0, y: 6)
    }

    /// 本机公钥展示 + 复制：引导用户把它加入目标机的 authorized_keys（复用 ConnectionConfigView 的样式）。
    @ViewBuilder private var publicKeyBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("conn.publicKeyHint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    if let pub = keyManager.publicKeyOpenSSH() {
                        UIPasteboard.general.string = pub
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    }
                } label: {
                    // 两个隐藏占位取并集锁定按钮尺寸，避免 checkmark/doc.on.doc 高度差导致卡片抖动。
                    ZStack {
                        Label("conn.copy", systemImage: "doc.on.doc").hidden()
                        Label("conn.copied", systemImage: "checkmark").hidden()
                        Label(copied ? "conn.copied" : "conn.copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .font(.caption)
                }
                .disabled(keyManager.publicKeyOpenSSH() == nil)
            }
            Text(keyManager.publicKeyOpenSSH() ?? "conn.generating")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.tertiarySystemGroupedBackground))
        )
    }

    /// 统一输入框包装：圆角描边 + 内边距（复用 ConnectionConfigView 样式）。
    private func field<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(.tertiarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color(.separator), lineWidth: 0.5)
            )
    }

    /// 保存：构造 MachineConfig（displayName 空则 MachineConfig 内部默认取 host），
    /// 调 addMachineAndConnect（自动切过去 + 连接 D13）；成功后 dismiss。
    private func save() {
        keyManager.generateIfNeeded()
        let name = displayName.trimmingCharacters(in: .whitespaces)
        let m = MachineConfig(
            displayName: name.isEmpty ? nil : name,
            host: host.trimmingCharacters(in: .whitespaces),
            user: user.trimmingCharacters(in: .whitespaces),
            sshPort: Int(sshPort) ?? 22)
        if sessions.addMachineAndConnect(m) {
            dismiss()
        }
    }
}
