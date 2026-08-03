import Foundation

/// 连接层信号帧（非 E2E）。由 relay-server 在一端离开时向仍在的对端明文下发，
/// 供接收端作「加速提示」。零知识不破：仅承载连接层事件，绝不含会话内容。
/// 靠 `kind` 字段与无 `kind` 的 `SecureEnvelope` 试解歧义（仿 `RejectHello`）。
/// 不进 HKDF/握手，不 bump `RelayProtocolVersion.tag`。
public struct RelaySignal: Codable, Sendable, Equatable {
    public var kind: String
    public var sessionId: String

    /// 「对端已离开」信号的 kind 常量。
    public static let peerLeftKind = "peer-left"

    public init(kind: String, sessionId: String) {
        self.kind = kind
        self.sessionId = sessionId
    }

    public func encoded() throws -> Data { try JSONEncoder().encode(self) }
    public init(decoding data: Data) throws {
        self = try JSONDecoder().decode(RelaySignal.self, from: data)
    }
}
