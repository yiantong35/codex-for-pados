import Foundation

/// 一台机器的连接配置（多机器 tab 容器的持久化单元）。
/// 非敏感项；鉴权私钥仍在 Keychain（KeyManager），一把公钥对所有机器通用。
struct MachineConfig: Codable, Identifiable, Equatable {
    let id: UUID
    var displayName: String
    var host: String
    var user: String
    var sshPort: Int
    var sockPath: String
    var lastActiveAt: Date?

    init(id: UUID = UUID(), displayName: String? = nil, host: String, user: String,
         sshPort: Int = 22, sockPath: String? = nil, lastActiveAt: Date? = nil) {
        self.id = id
        self.displayName = (displayName?.isEmpty == false) ? displayName! : host
        self.host = host
        self.user = user
        self.sshPort = sshPort
        self.sockPath = sockPath ?? Self.sockPath(forUser: user)
        self.lastActiveAt = lastActiveAt
    }

    /// control socket 路径由 SSH 用户名派生（迁自 ConnectionConfigView.sockPath）。
    static func sockPath(forUser user: String) -> String {
        "/Users/\(user)/.codex/app-server-control/app-server-control.sock"
    }

    /// 转为连接层 ConnectionConfig。
    var connectionConfig: ConnectionConfig {
        ConnectionConfig(host: host, user: user, sshPort: sshPort, controlSockPath: sockPath)
    }
}
