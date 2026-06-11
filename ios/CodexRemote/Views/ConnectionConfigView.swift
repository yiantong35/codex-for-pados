import SwiftUI

/// 连接配置界面：主机/端口/SSH 用户 + 密码或私钥。
/// 非敏感项（主机/端口/用户）存 `UserDefaults`；敏感项（私钥 PEM / 密码）存 `KeychainStore`。
/// 点击「连接」调用 `ConnectionStore.connect`，并把传输层 typed error 映射为明确中文文案。
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
        Form {
            Section("conn.section.mac") {
                TextField("conn.host", text: $host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("conn.sshPort", text: $sshPort)
                    .keyboardType(.numberPad)
                TextField("conn.sshUser", text: $user)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Toggle("conn.usePrivateKey", isOn: $usePrivateKey)
                SecureField(usePrivateKey ? "conn.privateKeyPlaceholder" : "conn.passwordPlaceholder",
                            text: $secret)
            }
            if let e = errorText {
                Section { Text(e).foregroundStyle(.red) }
            }
            Section {
                Button("conn.connect") { Task { await connect() } }
                    .disabled(host.isEmpty || user.isEmpty)
            }
        }
        .navigationTitle("conn.title")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { SettingsMenu() }
        }
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
