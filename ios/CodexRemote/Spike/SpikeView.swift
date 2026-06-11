// ⚠️ SPIKE 代码（Task 3）——临时验证视图，后续可删。

import SwiftUI

@available(macOS 15.0, *)
struct SpikeView: View {
    @State private var host = ""
    @State private var sshPort = "22"
    @State private var user = ""
    @State private var password = ""
    @State private var log = "未连接"
    @State private var busy = false

    private let runner = SpikeRunner()

    var body: some View {
        Form {
            Section("SSH") {
                TextField("Mac 主机/IP", text: $host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("SSH 端口", text: $sshPort)
                    .keyboardType(.numberPad)
                TextField("SSH 用户名", text: $user)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("SSH 密码", text: $password)
            }
            Section {
                Button(busy ? "连接中…" : "连接并握手") {
                    Task { await connect() }
                }
                .disabled(busy)
            }
            Section("日志") {
                Text(log)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
            }
        }
    }

    private func connect() async {
        busy = true
        log = "连接中…"
        defer { busy = false }
        do {
            log = try await runner.run(
                host: host,
                sshPort: Int(sshPort) ?? 22,
                user: user,
                password: password
            )
        } catch {
            log = "失败：\(error)"
        }
    }
}
