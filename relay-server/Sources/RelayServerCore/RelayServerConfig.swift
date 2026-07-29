import Foundation

/// relay-server 启动配置解析（抽出便于单测；`main.swift` 顶层执行不可测）。
public enum RelayServerConfig {
    /// 默认监听 loopback（`127.0.0.1`）；仅显式设置 `RELAY_HOST` 才绑定指定地址。
    ///
    /// 安全默认：不设 `RELAY_HOST` 时公网接口不可直达 relay-server 的 9000 端口，
    /// 杜绝未鉴权客户端绕过 TLS + Caddy 反代裸连。生产经 Caddy 反代对外暴露 `wss://`，
    /// relay 只监听 `127.0.0.1:9000`；`RELAY_HOST=0.0.0.0` 作逃生阀（本机排障 / 置于可信反代之后）。
    public static func resolveHost(env: [String: String]) -> String {
        env["RELAY_HOST"] ?? "127.0.0.1"
    }
}
