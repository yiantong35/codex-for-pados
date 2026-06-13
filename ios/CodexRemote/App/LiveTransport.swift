import Foundation

/// 生产环境的 transport 工厂：建立 SSH 连接并启动 `codex app-server --listen stdio://` exec 代理通道。
///
/// `SSHClientWrapper.connect` 直接返回已 start 的 `ProxyChannel`（即 MessageTransport），
/// 内部独占持有非 Sendable 的 Citadel client（见 SSHClient.swift 设计取舍）。
func liveTransportFactory(_ config: ConnectionConfig) async throws -> MessageTransport {
    try await SSHClientWrapper.connect(
        host: config.host,
        sshPort: config.sshPort,
        auth: config.auth)
}
