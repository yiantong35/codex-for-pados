/// Wire-level limits shared by every relay peer.
public enum RelayWireLimits {
    /// Maximum UTF-8 bytes in one WebSocket message.
    public static let maxMessageBytes = 1 << 20
    /// dialout 无法把超限 app-server response 原样送上 wire 时返回的 JSON-RPC 错误消息。
    public static let outboundResponseTooLargeMessage = "Relay response exceeds 1 MiB wire limit"
}
