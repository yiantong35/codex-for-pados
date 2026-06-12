import SwiftUI

/// 连接配置界面：主机/端口/SSH 用户 + 密码或私钥。
/// 非敏感项（主机/端口/用户）存 `UserDefaults`；敏感项（私钥 PEM / 密码）存 `KeychainStore`。
/// 点击「连接」调用 `ConnectionStore.connect`，并把传输层 typed error 映射为明确中文文案。
///
/// 视觉：去大标题，表单收敛为屏幕居中卡片（maxWidth 480，适配 iPad 11/13 寸），
/// 齿轮设置入口浮在右上角（带 safe-area 边距）。
struct ConnectionConfigView: View {
    @Environment(ConnectionStore.self) private var connection
    private let keychain = KeychainStore(service: "com.codexremote.ssh")

    @State private var host = UserDefaults.standard.string(forKey: "host") ?? ""
    @State private var sshPort = UserDefaults.standard.string(forKey: "sshPort") ?? "22"
    @State private var user = UserDefaults.standard.string(forKey: "sshUser") ?? ""
    @State private var secret = ""
    @State private var usePrivateKey = false
    @State private var errorText: String?

    var body: some View {
        ZStack {
            // 全屏分组背景，承托居中卡片，11/13 寸大屏自然留白。
            Color(.systemGroupedBackground)
                .ignoresSafeArea()

            // 垂直略偏上的居中卡片；内容超高时可滚动（横屏/小高度键盘弹起场景）。
            ScrollView {
                card
                    .frame(maxWidth: 480)
                    .frame(maxWidth: .infinity)
                    .padding(24)
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
                field {
                    SecureField(usePrivateKey ? "conn.privateKeyPlaceholder" : "conn.passwordPlaceholder",
                                text: $secret)
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
                Text("conn.connect")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(host.isEmpty || user.isEmpty)
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
        // 敏感项入 Keychain（私钥 PEM 或密码）。
        try? keychain.save(secret, for: "ssh-credential")

        // 私钥分支使用真实存在的 SSHAuth case：.ed25519(user:pem:passphrase:)。
        let auth: SSHAuth = usePrivateKey
            ? .ed25519(user: user, pem: secret, passphrase: nil)
            : .password(user: user, password: secret)
        let cfg = ConnectionConfig(host: host, sshPort: Int(sshPort) ?? 22, auth: auth)

        do {
            try await connection.connect(config: cfg)
            errorText = nil
        } catch TransportError.sshAuthFailed(let m) {
            errorText = String(localized: "conn.error.authFailed \(m)")
        } catch TransportError.appServerUnreachable {
            errorText = String(localized: "conn.error.appServerUnreachable")
        } catch {
            errorText = String(localized: "conn.error.generic \(String(describing: error))")
        }
    }
}
