import Foundation

/// 生产 transport 工厂：构造连 daemon 的 WSTransport（URL 含 ?token=）。
func liveTransportFactory(_ config: ConnectionConfig) async throws -> MessageTransport {
    let transport = WSTransport(url: config.wsURL)
    await transport.start()
    return transport
}
