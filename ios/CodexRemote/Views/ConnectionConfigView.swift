import SwiftUI

/// 连接配置界面：共享 daemon 接入参数（SSH host/user/port + 远端 control socket 路径）。
/// 非敏感项（host/user/sshPort/sockPath）存 `UserDefaults`；鉴权私钥在 Keychain（由 `KeyManager` 管）。
/// 展示本机 OpenSSH 公钥供复制——用户需把它加进 macmini 的 `~/.ssh/authorized_keys`。
/// 点击「连接」调用 `ConnectionStore.connect`，错误经 `phase` 派生为中文文案。
///
/// 视觉：去大标题，表单收敛为屏幕居中卡片（maxWidth 480，适配 iPad 11/13 寸），
/// 齿轮设置入口浮在右上角（带 safe-area 边距）。
struct ConnectionConfigView: View {
    @Environment(ConnectionStore.self) private var connection

    /// control socket 默认路径（T1.1 确认存在）。
    private static let defaultSockPath = "/Users/tangyujie/.codex/app-server-control/app-server-control.sock"

    @State private var host = UserDefaults.standard.string(forKey: "host") ?? ""
    @State private var user = UserDefaults.standard.string(forKey: "sshUser") ?? ""
    @State private var sshPort = UserDefaults.standard.string(forKey: "sshPort") ?? "22"
    @State private var sockPath = UserDefaults.standard.string(forKey: "sockPath") ?? ConnectionConfigView.defaultSockPath
    /// 本机 KeyManager：无密钥时生成，展示公钥供复制。
    @State private var keyManager = KeyManager()
    @State private var copied = false
    /// 启动自动重连一次性闸门：仅本次 app 生命周期内自动连一次，失败后不自动重试（避免循环）。
    @State private var didAutoConnect = false

    /// 错误文案直接由 phase 派生：重新点连接 → phase 变 connecting → 旧错误自动消失。
    private var errorText: String? {
        if case .failed(let msg) = connection.phase { return msg }
        return nil
    }

    /// 连接进行中（建连/握手任一阶段）：按钮转圈并禁用，给用户明确反馈。
    private var isConnecting: Bool {
        switch connection.phase {
        case .connecting, .initializing: return true
        default: return false
        }
    }

    /// 必填项是否齐全（host/user/sockPath 非空）。
    private var canConnect: Bool {
        !host.isEmpty && !user.isEmpty && !sockPath.isEmpty
    }

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()

            GeometryReader { geo in
                ScrollView {
                    card
                        .frame(maxWidth: 480)
                        .frame(maxWidth: .infinity)
                        .padding(24)
                        .frame(minHeight: geo.size.height)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            SettingsMenu()
                .font(.title3)
                .padding(20)
        }
        // 进入即确保本机密钥存在（幂等：已有不动），保证公钥可展示、连接前置满足。
        .onAppear { keyManager.generateIfNeeded() }
        // 启动自动重连：有上次连接信息(host+user+sock)且密钥已存、当前断开时，自动发起连接一次。
        .task {
            if !didAutoConnect, connection.phase == .disconnected,
               canConnect, keyManager.hasKey {
                didAutoConnect = true
                connect()
            }
        }
    }

    /// 居中卡片：顶部图标 + 小标题，下接字段、公钥块与连接按钮。
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
                    TextField("用户名（SSH user）", text: $user)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                field {
                    TextField("SSH 端口", text: $sshPort)
                        .keyboardType(.numberPad)
                }
                field {
                    TextField("control socket 路径", text: $sockPath)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }

            publicKeyBlock

            if let e = errorText {
                Text(e)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                connect()
            } label: {
                HStack(spacing: 8) {
                    if isConnecting { ProgressView().controlSize(.small).tint(.white) }
                    Text(isConnecting ? "conn.connecting" : "conn.connect")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canConnect || isConnecting)
        }
        .padding(28)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 16, x: 0, y: 6)
    }

    /// 本机公钥展示 + 复制：引导用户把它加入 macmini 的 authorized_keys。
    @ViewBuilder private var publicKeyBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("本机公钥（加入 macmini authorized_keys）")
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
                    Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .disabled(keyManager.publicKeyOpenSSH() == nil)
            }
            Text(keyManager.publicKeyOpenSSH() ?? "（生成中…）")
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

    /// 统一的输入框包装：圆角描边 + 内边距。
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

    /// 发起连接：保存非敏感参数（UserDefaults），构造共享 daemon ConnectionConfig 调 connect。
    /// 私钥不在此传递——由 ConnectionStore 的 transportFactory 闭包从 KeyManager 取。
    private func connect() {
        UserDefaults.standard.set(host, forKey: "host")
        UserDefaults.standard.set(user, forKey: "sshUser")
        UserDefaults.standard.set(sshPort, forKey: "sshPort")
        UserDefaults.standard.set(sockPath, forKey: "sockPath")
        keyManager.generateIfNeeded()
        connection.connect(config: ConnectionConfig(
            host: host, user: user,
            sshPort: Int(sshPort) ?? 22,
            controlSockPath: sockPath))
    }
}
