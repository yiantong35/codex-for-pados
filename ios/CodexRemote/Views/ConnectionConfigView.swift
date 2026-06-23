import SwiftUI

/// 连接配置界面：ws 主机/端口 + 鉴权 token。
/// 非敏感项（主机/端口）存 `UserDefaults`；敏感项（token）存 `KeychainStore`。
/// 点击「连接」调用 `ConnectionStore.connect`，并把传输层 typed error 映射为明确中文文案。
///
/// 视觉：去大标题，表单收敛为屏幕居中卡片（maxWidth 480，适配 iPad 11/13 寸），
/// 齿轮设置入口浮在右上角（带 safe-area 边距）。
struct ConnectionConfigView: View {
    @Environment(ConnectionStore.self) private var connection

    @State private var host = UserDefaults.standard.string(forKey: "host") ?? ""
    @State private var port = UserDefaults.standard.string(forKey: "wsPort") ?? "8799"
    @State private var token = (try? KeychainStore(service: "com.tangyujie.codexremote").load("wsToken")) ?? ""
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
        // 启动自动重连：有上次连接信息(主机+用户)且密钥已存、当前断开时，自动发起连接一次。
        // 失败留在本界面（phase=.failed），由用户手动重试，不自动循环。
        .task {
            if !didAutoConnect, connection.phase == .disconnected,
               !host.isEmpty, !token.isEmpty {
                didAutoConnect = true
                connect()
            }
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
                    SecureField("conn.token", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                field {
                    TextField("conn.port", text: $port)
                        .keyboardType(.numberPad)
                }
            }

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
            .disabled(host.isEmpty || token.isEmpty || isConnecting)
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

    /// 发起连接：保存 ws endpoint（UserDefaults）与 token（Keychain），用 token 构造 ConnectionConfig。
    /// 连接进度/错误经 `connection.phase` 反映（errorText 派生），不在此处 try/catch。
    private func connect() {
        UserDefaults.standard.set(host, forKey: "host")
        UserDefaults.standard.set(port, forKey: "wsPort")
        try? KeychainStore(service: "com.tangyujie.codexremote").save(token, for: "wsToken")
        connection.connect(config: ConnectionConfig(
            host: host, port: Int(port) ?? 8799, token: token))
    }
}
