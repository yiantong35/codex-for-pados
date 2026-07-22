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
    public var pairingCodeProof: Data    // HMAC-SHA256(key: pairingCode, msg: clientNonce)
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

/// 消息 4：dev → iPad。确认握手完成。
public struct SecureReady: Codable, Sendable, Equatable {
    public var sessionId: String
    public var keyEpoch: UInt32
    public var devDeviceId: String
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

    static func pairingCodeProof(pairingCode: String, clientNonce: Data) -> Data {
        let key = SymmetricKey(data: Data(pairingCode.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: clientNonce, using: key)
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
            pairingCodeProof: pairingCodeProof(pairingCode: pairingCode, clientNonce: clientNonce)
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
        // 常量时间比对 pairingCodeProof：dev 用自己持有的 pairingCode 重算。
        let key = SymmetricKey(data: Data(pairingCode.utf8))
        guard HMAC<SHA256>.isValidAuthenticationCode(h.pairingCodeProof,
                                                      authenticating: h.clientNonce,
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
