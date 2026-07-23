import NIOCore
import NIOSSL

/// 开发机拨出的客户端 TLS 接线：wss 时给 ws 通道前置 NIOSSL 客户端 handler。
public enum DialoutTLS {
    /// 构造到 relay 的客户端 TLS handler。`serverHostname` 用于 SNI / 证书主机名校验（须为主机名，非 IP）。
    public static func makeClientHandler(serverHostname: String) throws -> NIOSSLClientHandler {
        let context = try NIOSSLContext(configuration: .makeClientConfiguration())
        return try NIOSSLClientHandler(context: context, serverHostname: serverHostname)
    }

    /// 给 channel pipeline 前置 TLS handler（供 channelInitializer 在 wss 时调用）。
    public static func addClientTLS(to channel: Channel, serverHostname: String) -> EventLoopFuture<Void> {
        do {
            return channel.pipeline.addHandler(try makeClientHandler(serverHostname: serverHostname))
        } catch {
            return channel.eventLoop.makeFailedFuture(error)
        }
    }
}
