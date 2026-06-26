import Foundation

/// 传输层错误。覆盖 ws 传输的失败语义（rpc 错误、通道生命周期、未连接）。
enum TransportError: Error, Equatable {
    case proxyFailed(String)          // rpc 错误响应 / 传输建立失败
    case channelClosed(reason: String?)
    case notConnected
    case sshAuthFailed(String)        // SSH 鉴权/建连失败（ed25519 未被接受等）
    case handshakeFailed(String)      // ws 握手失败（无 101 / Accept 校验不过）
}
