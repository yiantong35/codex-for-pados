import Foundation

/// 连接方式（SSH 直连共享 daemon vs relay 中继）。
/// SSH 专有字段收进 `.ssh` case，避免散在 MachineConfig 顶层；relay 只需一段配对载荷字符串。
/// Codable：以 `kind` 判别子编码（`.ssh` 平铺 host/user/…，`.relay` 带 pairing）。
enum ConnectionKind: Codable, Equatable {
    case ssh(host: String, user: String, sshPort: Int, sockPath: String)
    case relay(pairing: String)

    private enum CodingKeys: String, CodingKey {
        case kind, host, user, sshPort, sockPath, pairing
    }
    private enum Kind: String, Codable { case ssh, relay }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ssh(let host, let user, let sshPort, let sockPath):
            try c.encode(Kind.ssh, forKey: .kind)
            try c.encode(host, forKey: .host)
            try c.encode(user, forKey: .user)
            try c.encode(sshPort, forKey: .sshPort)
            try c.encode(sockPath, forKey: .sockPath)
        case .relay(let pairing):
            try c.encode(Kind.relay, forKey: .kind)
            try c.encode(pairing, forKey: .pairing)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .ssh:
            self = .ssh(host: try c.decode(String.self, forKey: .host),
                        user: try c.decode(String.self, forKey: .user),
                        sshPort: try c.decode(Int.self, forKey: .sshPort),
                        sockPath: try c.decode(String.self, forKey: .sockPath))
        case .relay:
            self = .relay(pairing: try c.decode(String.self, forKey: .pairing))
        }
    }
}

/// 一台机器的连接配置（多机器 tab 容器的持久化单元）。
/// 非敏感项；SSH 鉴权私钥仍在 Keychain（KeyManager），一把公钥对所有机器通用。
/// 连接方式统一收进 `connection: ConnectionKind`（`.ssh` / `.relay`），
/// 旧扁平字段（host/user/sshPort/sockPath）经自定义解码迁移为 `.ssh`。
struct MachineConfig: Codable, Identifiable, Equatable {
    let id: UUID
    var displayName: String
    var connection: ConnectionKind
    var lastActiveAt: Date?

    /// 主构造器（kind 显式）。displayName 为空则回落到 SSH host（relay 无 host 时回落空串→由调用方保证非空）。
    init(id: UUID = UUID(), displayName: String? = nil,
         connection: ConnectionKind, lastActiveAt: Date? = nil) {
        self.id = id
        self.connection = connection
        let fallback: String
        if case .ssh(let host, _, _, _) = connection { fallback = host } else { fallback = "" }
        self.displayName = (displayName?.isEmpty == false) ? displayName! : fallback
        self.lastActiveAt = lastActiveAt
    }

    /// SSH 便利构造器：保持旧 `MachineConfig(host:user:...)` 调用点零改动。
    init(id: UUID = UUID(), displayName: String? = nil, host: String, user: String,
         sshPort: Int = 22, sockPath: String? = nil, lastActiveAt: Date? = nil) {
        self.init(id: id, displayName: displayName,
                  connection: .ssh(host: host, user: user, sshPort: sshPort,
                                   sockPath: sockPath ?? Self.sockPath(forUser: user)),
                  lastActiveAt: lastActiveAt)
    }

    // MARK: - Codable（含旧扁平格式迁移）

    private enum CodingKeys: String, CodingKey {
        case id, displayName, connection, lastActiveAt
        // 旧扁平格式的字段（无 `connection`）：
        case host, user, sshPort, sockPath
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.lastActiveAt = try c.decodeIfPresent(Date.self, forKey: .lastActiveAt)
        // 优先解新结构 connection；缺失则从旧扁平字段迁移为 .ssh（数据不丢）。
        if let kind = try c.decodeIfPresent(ConnectionKind.self, forKey: .connection) {
            self.connection = kind
        } else {
            let host = try c.decode(String.self, forKey: .host)
            let user = try c.decode(String.self, forKey: .user)
            let sshPort = try c.decodeIfPresent(Int.self, forKey: .sshPort) ?? 22
            let sockPath = try c.decodeIfPresent(String.self, forKey: .sockPath)
                ?? Self.sockPath(forUser: user)
            self.connection = .ssh(host: host, user: user, sshPort: sshPort, sockPath: sockPath)
        }
        // displayName 缺失时回落 SSH host（与构造器一致）。
        if let name = try c.decodeIfPresent(String.self, forKey: .displayName), !name.isEmpty {
            self.displayName = name
        } else if case .ssh(let host, _, _, _) = self.connection {
            self.displayName = host
        } else {
            self.displayName = ""
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(connection, forKey: .connection)
        try c.encodeIfPresent(lastActiveAt, forKey: .lastActiveAt)
    }

    // MARK: - SSH 兼容 shim（保持旧调用点读 host/user/... 不改）

    /// SSH host（relay 时为空串）。旧调用点（MachineFormView/测试）继续读用。
    var host: String { if case .ssh(let h, _, _, _) = connection { return h } else { return "" } }
    var user: String { if case .ssh(_, let u, _, _) = connection { return u } else { return "" } }
    var sshPort: Int { if case .ssh(_, _, let p, _) = connection { return p } else { return 22 } }
    var sockPath: String { if case .ssh(_, _, _, let s) = connection { return s } else { return "" } }

    /// control socket 路径由 SSH 用户名派生（迁自 ConnectionConfigView.sockPath）。
    static func sockPath(forUser user: String) -> String {
        "/Users/\(user)/.codex/app-server-control/app-server-control.sock"
    }

    /// 转为连接层 ConnectionConfig（按 kind 分派）。
    /// `.ssh` → SSH 直连字段；`.relay` → 带 pairing 载荷，transportFactory 据此构造 RelayTransport。
    var connectionConfig: ConnectionConfig {
        switch connection {
        case .ssh(let host, let user, let sshPort, let sockPath):
            return ConnectionConfig(host: host, user: user, sshPort: sshPort,
                                    controlSockPath: sockPath)
        case .relay(let pairing):
            return ConnectionConfig(relayPairing: pairing)
        }
    }
}
