import Foundation

/// 传输层错误。覆盖 remote-connection spec 的失败语义（SSH 鉴权、app-server 可达性、通道生命周期）。
enum TransportError: Error, Equatable {
    case sshAuthFailed(String)        // remote-connection: SSH 鉴权失败
    case appServerUnreachable         // remote-connection: app-server 不可达
    case proxyFailed(String)          // exec codex app-server proxy 失败
    case channelClosed(reason: String?)
    case notConnected
}
