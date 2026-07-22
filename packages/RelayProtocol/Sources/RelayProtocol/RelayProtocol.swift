import Foundation

/// 协议版本 tag，进 HKDF info 与握手校验，改协议时 bump。
public enum RelayProtocolVersion {
    public static let tag = "codexrelay-e2ee-v1"
    public static let wire: UInt8 = 1
}
