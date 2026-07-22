import Foundation

/// 谁发的这一帧（决定 nonce 方向绑定 + 路由 role）。
public enum RelayPeer: String, Codable, Sendable, Equatable {
    case iPad
    case devMachine
}

/// 加密帧信封。header 明文（路由/防重放），ciphertext+tag 是 AES-GCM 密文体。
/// base64 编码二进制字段，整体 JSON，一条 = 一个 ws text frame。
public struct SecureEnvelope: Codable, Sendable, Equatable {
    public var v: UInt8
    public var sessionId: String
    public var keyEpoch: UInt32
    public var sender: RelayPeer
    public var counter: UInt64
    public var ciphertext: Data
    public var tag: Data

    public init(v: UInt8, sessionId: String, keyEpoch: UInt32,
                sender: RelayPeer, counter: UInt64, ciphertext: Data, tag: Data) {
        self.v = v; self.sessionId = sessionId; self.keyEpoch = keyEpoch
        self.sender = sender; self.counter = counter
        self.ciphertext = ciphertext; self.tag = tag
    }

    public func encoded() throws -> Data { try JSONEncoder().encode(self) }
    public init(decoding data: Data) throws {
        self = try JSONDecoder().decode(SecureEnvelope.self, from: data)
    }
}
