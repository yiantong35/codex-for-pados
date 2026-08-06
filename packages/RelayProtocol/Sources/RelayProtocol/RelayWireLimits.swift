/// Wire-level limits shared by every relay peer.
public enum RelayWireLimits {
    /// Maximum UTF-8 bytes in one WebSocket message.
    public static let maxMessageBytes = 1 << 20
}
