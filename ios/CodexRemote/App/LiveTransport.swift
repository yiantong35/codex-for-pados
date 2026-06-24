import Foundation

/// 生产 transport 工厂：构造连官方 ws app-server 的 WSTransport。
/// token 经 ws 握手的 Authorization: Bearer header 传递（官方 --ws-auth capability-token），
/// 不进 URL query，避免日志/历史泄漏。
func liveTransportFactory(_ config: ConnectionConfig) async throws -> MessageTransport {
    let transport = WSTransport(url: config.wsURL, bearerToken: config.token)
    await transport.start()
    return transport
}
