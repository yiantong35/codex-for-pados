import Foundation
import Crypto

/// 握手编排失败原因。
public enum HandshakeError: Error, Equatable {
    case pairingCodeMismatch
    case badServerSignature
    case badClientSignature
    case versionMismatch
}

// MARK: - 4 消息结构

/// 消息 1：iPad → dev。pairingCode 不明文过线，只带 HMAC 证明。
public struct ClientHello: Codable, Sendable, Equatable {
    public var protocolVersion: String
    public var sessionId: String
    public var ipadDeviceId: String
    public var ipadIdentityPub: Data     // Ed25519 raw
    public var ipadEphemeralPub: Data    // X25519 raw
    public var clientNonce: Data
    public var pairingCodeProof: Data    // HMAC-SHA256(key: pairingCode, msg: Transcript.encode(整条 ClientHello 除 proof 外全字段))
}

/// 消息 2：dev → iPad。带 dev 身份公钥与对 transcript 的签名，回显 clientNonce。
public struct ServerHello: Codable, Sendable, Equatable {
    public var devDeviceId: String
    public var devIdentityPub: Data      // Ed25519 raw
    public var devEphemeralPub: Data     // X25519 raw
    public var serverNonce: Data
    public var keyEpoch: UInt32
    public var echoedClientNonce: Data
    public var devSignature: Data        // Ed25519 over transcript
}

/// 消息 3：iPad → dev。iPad 对 `transcript + "client-auth"` 的签名。
public struct ClientAuth: Codable, Sendable, Equatable {
    public var sessionId: String
    public var ipadDeviceId: String
    public var keyEpoch: UInt32
    public var ipadSignature: Data       // Ed25519 over transcript + "client-auth"
}

/// 消息 4：dev → iPad。确认握手完成，并回传该 iPad 的稳定 sessionId（加密走已建通道）。
public struct SecureReady: Codable, Sendable, Equatable {
    public var sessionId: String
    public var keyEpoch: UInt32
    public var devDeviceId: String
    public var stableSessionId: String     // 新增：iPad 首次配对消费并持久化，供后续复连直连
    public init(sessionId: String, keyEpoch: UInt32, devDeviceId: String, stableSessionId: String) {
        self.sessionId = sessionId; self.keyEpoch = keyEpoch
        self.devDeviceId = devDeviceId; self.stableSessionId = stableSessionId
    }
}

// MARK: - 过线拒绝消息（附加式，不改上面 4 消息）

/// 握手拒绝原因（过线枚举，rawValue 稳定用于跨端序列化）。
public enum RejectReason: String, Codable, Sendable, Equatable {
    case trustRevoked          // iPad 曾受信任、现已被撤销
    case untrusted             // iPad 不在信任列表且未持有效 pairingCode
    case pairingInvalid        // 首次配对 proof 校验失败 / 口令已用 / 过期
    case versionMismatch
}

/// 独立过线拒绝消息：dev 握手拒绝时主动发一条再关连接（而非静默 close），
/// 使 iPad 能区分「应用层拒绝」与「传输层失败」。带独有 `kind` tag 供 iPad 类型判别
/// （ServerHello 没有 `kind` 字段，解码 RejectHello 时会因缺失该 required 字段而失败）。
public struct RejectHello: Codable, Sendable, Equatable {
    public var kind: String
    public var sessionId: String
    public var reason: RejectReason
    public init(sessionId: String, reason: RejectReason) {
        self.kind = "reject"; self.sessionId = sessionId; self.reason = reason
    }
}

// MARK: - 编排

/// 4 消息双向认证握手编排。
///
/// 信任建立：
/// - iPad 用带外获得的 dev 身份公钥验 ServerHello 的 devSignature（防冒充开发机）。
/// - dev 用一次性 pairingCode 重算 proof 比对，并用 ClientHello 里的 iPad 身份公钥验 ClientAuth
///   的 ipadSignature（防未授权 iPad 接管开发机）。
/// 两端签名与密钥派生共用同一个逐字节一致的 transcript。
public enum Handshake {

    /// 两端一致的 transcript：所有握手公开字段按固定顺序经 Transcript.encode 串接。
    static func transcript(clientHello h: ClientHello, serverHello s: ServerHello) -> Data {
        Transcript.encode([
            Data(RelayProtocolVersion.tag.utf8),
            Data(h.sessionId.utf8),
            Data(h.ipadDeviceId.utf8),   // deviceId 进签名 transcript，被双向签名覆盖（I2）
            Data(s.devDeviceId.utf8),
            h.ipadIdentityPub,
            s.devIdentityPub,
            h.ipadEphemeralPub,
            s.devEphemeralPub,
            h.clientNonce,
            s.serverNonce,
            withUnsafeBytes(of: s.keyEpoch.bigEndian) { Data($0) }
        ])
    }

    /// 一次性配对口令证明的输入：整条 ClientHello（除 proof 自身外全字段），
    /// 固定顺序经 Transcript.encode 长度前缀编码——防拼接歧义、两端逐字节一致。
    /// F1：由此把 proof 覆盖从「仅 clientNonce」扩到「协议版本/sessionId/ipadDeviceId/
    /// 身份公钥/临时公钥/clientNonce」，杜绝复用合法 nonce+proof 后替换公钥的认证绕过。
    static func pairingProofMessage(protocolVersion: String,
                                    sessionId: String,
                                    ipadDeviceId: String,
                                    ipadIdentityPub: Data,
                                    ipadEphemeralPub: Data,
                                    clientNonce: Data) -> Data {
        Transcript.encode([
            Data(protocolVersion.utf8),
            Data(sessionId.utf8),
            Data(ipadDeviceId.utf8),
            ipadIdentityPub,
            ipadEphemeralPub,
            clientNonce
        ])
    }

    static func pairingCodeProof(pairingCode: String, message: Data) -> Data {
        let key = SymmetricKey(data: Data(pairingCode.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: key)
        return Data(mac)
    }

    // 步骤 1：iPad 构造 ClientHello。
    public static func makeClientHello(sessionId: String,
                                       ipadDeviceId: String,
                                       ipadIdentityPub: Data,
                                       ipadEphemeralPub: Data,
                                       clientNonce: Data,
                                       pairingCode: String) -> ClientHello {
        ClientHello(
            protocolVersion: RelayProtocolVersion.tag,
            sessionId: sessionId,
            ipadDeviceId: ipadDeviceId,
            ipadIdentityPub: ipadIdentityPub,
            ipadEphemeralPub: ipadEphemeralPub,
            clientNonce: clientNonce,
            pairingCodeProof: pairingCodeProof(
                pairingCode: pairingCode,
                message: pairingProofMessage(
                    protocolVersion: RelayProtocolVersion.tag,
                    sessionId: sessionId,
                    ipadDeviceId: ipadDeviceId,
                    ipadIdentityPub: ipadIdentityPub,
                    ipadEphemeralPub: ipadEphemeralPub,
                    clientNonce: clientNonce))
        )
    }

    // 步骤 2：dev 处理 ClientHello（先验协议版本与 pairingCodeProof）并签名构造 ServerHello。
    public static func makeServerHello(clientHello h: ClientHello,
                                       devDeviceId: String,
                                       devIdentity: Curve25519.Signing.PrivateKey,
                                       devEphemeralPub: Data,
                                       serverNonce: Data,
                                       keyEpoch: UInt32,
                                       pairingCode: String) throws -> ServerHello {
        guard h.protocolVersion == RelayProtocolVersion.tag else {
            throw HandshakeError.versionMismatch
        }
        // 常量时间比对 pairingCodeProof：dev 用自己持有的 pairingCode + 完整 ClientHello 重算。
        // F1：以整条 ClientHello（除 proof 外全字段）重算——替换身份/临时公钥/deviceId 即失配被拒。
        let key = SymmetricKey(data: Data(pairingCode.utf8))
        let proofMsg = pairingProofMessage(
            protocolVersion: h.protocolVersion,
            sessionId: h.sessionId,
            ipadDeviceId: h.ipadDeviceId,
            ipadIdentityPub: h.ipadIdentityPub,
            ipadEphemeralPub: h.ipadEphemeralPub,
            clientNonce: h.clientNonce)
        guard HMAC<SHA256>.isValidAuthenticationCode(h.pairingCodeProof,
                                                      authenticating: proofMsg,
                                                      using: key) else {
            throw HandshakeError.pairingCodeMismatch
        }
        // 先组半成品 ServerHello（signature 待填），以便算出与 iPad 一致的 transcript。
        var s = ServerHello(devDeviceId: devDeviceId,
                            devIdentityPub: devIdentity.publicKey.rawRepresentation,
                            devEphemeralPub: devEphemeralPub,
                            serverNonce: serverNonce,
                            keyEpoch: keyEpoch,
                            echoedClientNonce: h.clientNonce,
                            devSignature: Data())
        let tr = transcript(clientHello: h, serverHello: s)
        s.devSignature = try devIdentity.signature(for: tr)
        return s
    }

    /// 受信任复连：iPad 身份已在 dev 信任列表内，免一次性 pairingCode（proof 留空）。
    /// 除跳过 proof 校验外，与 makeServerHello 逐字节一致（同 transcript、同签名）。
    /// 安全：iPad 的 Ed25519 身份签名验证仍在 verifyClientAuthAndFinish 中照常执行，未弱化。
    public static func makeServerHelloTrusted(clientHello h: ClientHello,
                                              devDeviceId: String,
                                              devIdentity: Curve25519.Signing.PrivateKey,
                                              devEphemeralPub: Data,
                                              serverNonce: Data,
                                              keyEpoch: UInt32) throws -> ServerHello {
        guard h.protocolVersion == RelayProtocolVersion.tag else {
            throw HandshakeError.versionMismatch
        }
        // 受信任复连不验 pairingCodeProof——判定权在 dev 侧信任列表；验签在后续步骤照常执行。
        // 先组半成品 ServerHello（signature 待填），以便算出与 iPad 一致的 transcript。
        var s = ServerHello(devDeviceId: devDeviceId,
                            devIdentityPub: devIdentity.publicKey.rawRepresentation,
                            devEphemeralPub: devEphemeralPub,
                            serverNonce: serverNonce,
                            keyEpoch: keyEpoch,
                            echoedClientNonce: h.clientNonce,
                            devSignature: Data())
        let tr = transcript(clientHello: h, serverHello: s)
        s.devSignature = try devIdentity.signature(for: tr)
        return s
    }

    // 步骤 3：iPad 用带外得到的 dev 身份公钥验 devSignature，通过后签名构造 ClientAuth。
    public static func verifyServerHelloAndMakeClientAuth(
        clientHello h: ClientHello,
        serverHello s: ServerHello,
        devIdentityPub: Data,
        ipadIdentity: Curve25519.Signing.PrivateKey
    ) throws -> ClientAuth {
        guard let devPub = try? Curve25519.Signing.PublicKey(rawRepresentation: devIdentityPub) else {
            throw HandshakeError.badServerSignature
        }
        // M1：显式校验回显的 clientNonce，消除死字段（transcript 用的是 h.clientNonce）。
        guard s.echoedClientNonce == h.clientNonce else {
            throw HandshakeError.badServerSignature
        }
        let tr = transcript(clientHello: h, serverHello: s)
        guard devPub.isValidSignature(s.devSignature, for: tr) else {
            throw HandshakeError.badServerSignature
        }
        let ipadSig = try ipadIdentity.signature(for: tr + Data("client-auth".utf8))
        return ClientAuth(sessionId: h.sessionId,
                          ipadDeviceId: h.ipadDeviceId,
                          keyEpoch: s.keyEpoch,
                          ipadSignature: ipadSig)
    }

    // 步骤 4：dev 用 ClientHello 里的 iPad 身份公钥验 ipadSignature，通过后 derive 建 SecureSession。
    public static func verifyClientAuthAndFinish(
        clientHello h: ClientHello,
        serverHello s: ServerHello,
        clientAuth a: ClientAuth,
        devEphemeral: Curve25519.KeyAgreement.PrivateKey
    ) throws -> SecureSession {
        guard let ipadPub = try? Curve25519.Signing.PublicKey(rawRepresentation: h.ipadIdentityPub) else {
            throw HandshakeError.badClientSignature
        }
        let tr = transcript(clientHello: h, serverHello: s)
        guard ipadPub.isValidSignature(a.ipadSignature, for: tr + Data("client-auth".utf8)) else {
            throw HandshakeError.badClientSignature
        }
        let peerEph = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: h.ipadEphemeralPub)
        let keys = try KeySchedule.derive(myEphemeral: devEphemeral,
                                          peerEphemeralPub: peerEph,
                                          transcript: tr,
                                          context: context(clientHello: h, serverHello: s))
        return SecureSession(role: .devMachine, keys: keys,
                             sessionId: h.sessionId, keyEpoch: s.keyEpoch)
    }

    // iPad 侧收尾：即便调用方漏了步骤 3，此处仍在 derive 前重新验 devSignature，
    // 使“建立加密通道”与“验证开发机身份”成为不可分割的原子操作（认证 by-construction）。
    public static func finishClient(clientHello h: ClientHello,
                                    serverHello s: ServerHello,
                                    ipadEphemeral: Curve25519.KeyAgreement.PrivateKey,
                                    devIdentityPub: Data) throws -> SecureSession {
        // derive 前重新验 devSignature：与 verifyServerHelloAndMakeClientAuth 同一段逻辑，
        // 保证漏调步骤 3 时仍不会与冒充的开发机建通道。
        guard let devPub = try? Curve25519.Signing.PublicKey(rawRepresentation: devIdentityPub) else {
            throw HandshakeError.badServerSignature
        }
        let tr = transcript(clientHello: h, serverHello: s)
        guard devPub.isValidSignature(s.devSignature, for: tr) else {
            throw HandshakeError.badServerSignature
        }
        let peerEph = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: s.devEphemeralPub)
        let keys = try KeySchedule.derive(myEphemeral: ipadEphemeral,
                                          peerEphemeralPub: peerEph,
                                          transcript: tr,
                                          context: context(clientHello: h, serverHello: s))
        return SecureSession(role: .iPad, keys: keys,
                             sessionId: h.sessionId, keyEpoch: s.keyEpoch)
    }

    private static func context(clientHello h: ClientHello, serverHello s: ServerHello) -> KeySchedule.Context {
        KeySchedule.Context(sessionId: h.sessionId,
                            devDeviceId: s.devDeviceId,
                            ipadDeviceId: h.ipadDeviceId,
                            keyEpoch: s.keyEpoch)
    }
}
