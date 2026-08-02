import Foundation

/// 传输层错误。覆盖 ws 传输的失败语义（rpc 错误、通道生命周期、未连接）。
enum TransportError: Error, Equatable {
    case proxyFailed(String)          // rpc 错误响应 / 传输·通道建立失败（含 relay 地址非法、明文 ws 拒绝）
    case channelClosed(reason: String?)
    case notConnected
    case handshakeFailed(String)      // ws 握手失败（无 101 / Accept 校验不过）
    case trustRevoked                 // 开发机移除信任（收 RejectHello）：可判别类型，供 connect 引导重新配对
}
