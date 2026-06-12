import SwiftUI

/// 连接配置界面：主机/端口/SSH 用户 + 密码或私钥。
/// 非敏感项（主机/端口/用户）存 `UserDefaults`；敏感项（私钥 PEM / 密码）存 `KeychainStore`。
/// 点击「连接」调用 `ConnectionStore.connect`，并把传输层 typed error 映射为明确中文文案。
///
/// 视觉：去大标题，表单收敛为屏幕居中卡片（maxWidth 480，适配 iPad 11/13 寸），
/// 齿轮设置入口浮在右上角（带 safe-area 边距）。
struct ConnectionConfigView: View {
    @Environment(ConnectionStore.self) private var connection
    @Environment(KeyManager.self) private var keyManager
    private let keychain = KeychainStore(service: "com.codexremote.ssh")

    @State private var host = UserDefaults.standard.string(forKey: "host") ?? ""
    @State private var sshPort = UserDefaults.standard.string(forKey: "sshPort") ?? "22"
    @State private var user = UserDefaults.standard.string(forKey: "sshUser") ?? ""
    @State private var secret = ""
    @State private var usePrivateKey = false
    @State private var errorText: String?

    /// 连接进行中（SSH/exec/握手任一阶段）：按钮转圈并禁用，给用户明确反馈。
    private var isConnecting: Bool {
        switch connection.phase {
        case .sshConnecting, .execProxy, .initializing: return true
        default: return false
        }
    }

    var body: some View {
        ZStack {
            // 全屏分组背景，承托居中卡片，11/13 寸大屏自然留白。
            Color(.systemGroupedBackground)
                .ignoresSafeArea()

            // 水平 + 垂直居中的卡片；内容超高时（横屏/键盘弹起）自动可滚动。
            GeometryReader { geo in
                ScrollView {
                    card
                        .frame(maxWidth: 480)
                        .frame(maxWidth: .infinity)
                        .padding(24)
                        .frame(minHeight: geo.size.height)   // 撑满屏高 → 卡片垂直居中
                }
            }
        }
        // 齿轮浮在右上角，距顶/右各留边距，不贴状态栏。
        .overlay(alignment: .topTrailing) {
            SettingsMenu()
                .font(.title3)
                .padding(20)
        }
    }

    /// 居中卡片：顶部图标 + 小标题，下接字段与连接按钮。
    private var card: some View {
        VStack(spacing: 20) {
            VStack(spacing: 10) {
                Image(systemName: "macbook.and.iphone")
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(.tint)
                Text("conn.cardTitle")
                    .font(.title2.weight(.semibold))
            }
            .padding(.top, 4)

            VStack(spacing: 14) {
                field {
                    TextField("conn.host", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                field {
                    TextField("conn.sshPort", text: $sshPort)
                        .keyboardType(.numberPad)
                }
                field {
                    TextField("conn.sshUser", text: $user)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Toggle("conn.usePrivateKey", isOn: $usePrivateKey)
                    .padding(.vertical, 2)
                if usePrivateKey {
                    KeyAreaView()
                } else {
                    field {
                        SecureField("conn.passwordPlaceholder", text: $secret)
                    }
                }
            }

            if let e = errorText {
                Text(e)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                Task { await connect() }
            } label: {
                HStack(spacing: 8) {
                    if isConnecting { ProgressView().controlSize(.small).tint(.white) }
                    Text(isConnecting ? "conn.connecting" : "conn.connect")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(host.isEmpty || user.isEmpty || isConnecting)
        }
        .padding(28)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 16, x: 0, y: 6)
    }

    /// 统一的输入框包装：圆角描边 + 内边距，让裸 TextField 在卡片内视觉整洁。
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

    private func connect() async {
        // 非敏感项落 UserDefaults。
        UserDefaults.standard.set(host, forKey: "host")
        UserDefaults.standard.set(sshPort, forKey: "sshPort")
        UserDefaults.standard.set(user, forKey: "sshUser")

        let auth: SSHAuth
        if usePrivateKey {
            // app 内生成并复用的 ed25519 密钥（CryptoKit 直传），不再粘贴 PEM。
            keyManager.generateIfNeeded()
            guard let key = keyManager.privateKey() else {
                errorText = String(localized: "conn.error.noKey")
                return
            }
            auth = .ed25519Key(user: user, key: key)
        } else {
            // 密码入 Keychain。
            try? keychain.save(secret, for: "ssh-credential")
            auth = .password(user: user, password: secret)
        }
        let cfg = ConnectionConfig(host: host, sshPort: Int(sshPort) ?? 22, auth: auth)

        do {
            try await connection.connect(config: cfg)
            errorText = nil
        } catch TransportError.sshAuthFailed(let m) {
            errorText = String(localized: "conn.error.authFailed \(m)")
        } catch TransportError.appServerUnreachable {
            errorText = String(localized: "conn.error.appServerUnreachable")
        } catch {
            // 含超时（ConnectionTimeoutError）在内的其它错误：用 localizedDescription 给可读文案。
            errorText = String(localized: "conn.error.generic \(error.localizedDescription)")
        }
    }
}

/// 连接密钥区：未生成时给「生成」按钮；已生成时显示指纹 + 复制公钥 + 安装提示 + 重新生成。
/// 抽成独立 View 以便单独快照与复用；密钥状态来自环境注入的 KeyManager，自动反映 hasKey。
struct KeyAreaView: View {
    @Environment(KeyManager.self) private var keyManager
    @State private var showRegenerateAlert = false
    @State private var copiedHint = false

    var body: some View {
        Group {
            if !keyManager.hasKey {
                Button {
                    keyManager.generateIfNeeded()
                } label: {
                    Label("conn.key.generate", systemImage: "key.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            } else {
                generatedArea
            }
        }
        .alert("conn.key.regenerate.title", isPresented: $showRegenerateAlert) {
            Button("conn.key.regenerate.confirm", role: .destructive) {
                keyManager.regenerate()
            }
            Button("common.cancel", role: .cancel) {}
        } message: {
            Text("conn.key.regenerate.message")
        }
    }

    private var generatedArea: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("conn.key.generated", systemImage: "checkmark.seal.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.green)

            if let fp = keyManager.fingerprintSHA256() {
                Text(fp)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Text("conn.key.installHint")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let cmd = installCommand {
                Text(cmd)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(.tertiarySystemGroupedBackground))
                    )
            }

            HStack(spacing: 10) {
                Button {
                    copyPublicKey()
                } label: {
                    Label(copiedHint ? "conn.key.copied" : "conn.key.copyPublic",
                          systemImage: copiedHint ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered)

                Button(role: .destructive) {
                    showRegenerateAlert = true
                } label: {
                    Label("conn.key.regenerate", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.regular)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.tertiarySystemGroupedBackground))
        )
    }

    /// 安装到 Mac 的命令（含完整公钥，UI 截断显示但复制时取全文）。
    private var installCommand: String? {
        guard let pub = keyManager.publicKeyOpenSSH() else { return nil }
        return "echo '\(pub)' >> ~/.ssh/authorized_keys"
    }

    private func copyPublicKey() {
        guard let pub = keyManager.publicKeyOpenSSH() else { return }
        UIPasteboard.general.string = pub
        copiedHint = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copiedHint = false
        }
    }
}
