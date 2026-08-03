import Foundation

/// 谁发的这一帧（决定 nonce 方向绑定 + 路由 role）。
public enum RelayPeer: String, Codable, Sendable, Equatable {
    case iPad
    case devMachine
}

/// 加密帧类型标签（明文 header，与 sender/counter 同层）。接收端以此驱动分发，替代按 JSON 形状隐式推断。
/// 未定义 raw value 解码即抛错（decode 层 fail-closed）；标签进 AAD（AEAD 层 fail-closed）。
/// 不复用 `v`（v 是加密版本，语义不同不过载）。
public enum RelayFrameKind: UInt8, Codable, Sendable, Equatable {
    case appData = 0        // 应用数据（JSON-RPC 明文帧）
    case secureReady = 1    // 安全控制信令（dev 握手后加密回传 stableSessionId 的 SecureReady）
}

/// 加密帧信封。header 明文（路由/防重放/类型），ciphertext+tag 是 AES-GCM 密文体。
/// 明文 header 整体经 AES-GCM AAD 认证（篡改任一字段 → open fail-closed）。
/// base64 编码二进制字段，整体 JSON，一条 = 一个 ws text frame。
public struct SecureEnvelope: Codable, Sendable, Equatable {
    public var v: UInt8
    public var sessionId: String
    public var keyEpoch: UInt32
    public var sender: RelayPeer
    public var counter: UInt64
    public var kind: RelayFrameKind
    public var ciphertext: Data
    public var tag: Data

    public init(v: UInt8, sessionId: String, keyEpoch: UInt32,
                sender: RelayPeer, counter: UInt64, kind: RelayFrameKind,
                ciphertext: Data, tag: Data) {
        self.v = v; self.sessionId = sessionId; self.keyEpoch = keyEpoch
        self.sender = sender; self.counter = counter; self.kind = kind
        self.ciphertext = ciphertext; self.tag = tag
    }

    public func encoded() throws -> Data { try JSONEncoder().encode(self) }
    public init(decoding data: Data) throws {
        self = try JSONDecoder().decode(SecureEnvelope.self, from: data)
    }

    /// 明文 header 的确定性规范编码，用作 AES-GCM AAD。**收发共用唯一实现源**——
    /// 固定字段序、固定大端序、sessionId 长度前缀防歧义。任一字段被篡改 → AAD 失配 → open 抛错。
    public static func headerAAD(v: UInt8, keyEpoch: UInt32, sessionId: String,
                                 sender: RelayPeer, counter: UInt64, kind: RelayFrameKind) -> Data {
        var d = Data()
        d.append(v)                                                            // UInt8
        withUnsafeBytes(of: keyEpoch.bigEndian) { d.append(contentsOf: $0) }   // UInt32 BE
        let sid = Data(sessionId.utf8)
        withUnsafeBytes(of: UInt32(sid.count).bigEndian) { d.append(contentsOf: $0) } // 长度前缀
        d.append(sid)
        d.append(sender == .iPad ? 1 : 2)                                      // sender 标志
        withUnsafeBytes(of: counter.bigEndian) { d.append(contentsOf: $0) }    // UInt64 BE
        d.append(kind.rawValue)                                                // UInt8
        return d
    }

    /// 本信封 header 的 AAD（转调 headerAAD，单一实现源）。
    public func aad() -> Data {
        Self.headerAAD(v: v, keyEpoch: keyEpoch, sessionId: sessionId,
                       sender: sender, counter: counter, kind: kind)
    }
}
