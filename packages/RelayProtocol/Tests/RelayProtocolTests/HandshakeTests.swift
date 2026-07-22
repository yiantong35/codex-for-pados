import Testing
import Foundation
import Crypto
@testable import RelayProtocol

/// 内存跑完 iPad↔dev 四消息握手（不经网络），用于验证双向认证与密钥建立。
/// - iPad 侧只持有 dev 的身份**公钥**（模拟从配对载荷带外获得），不共享私钥。
/// - pairingCode 两端各持一份（模拟带外配对）。
private struct HandshakeHarness {
    // 身份密钥（Ed25519）
    let ipadIdentity = Curve25519.Signing.PrivateKey()
    let devIdentity  = Curve25519.Signing.PrivateKey()
    // 临时交换密钥（X25519）
    let ipadEphemeral = Curve25519.KeyAgreement.PrivateKey()
    let devEphemeral  = Curve25519.KeyAgreement.PrivateKey()

    let sessionId = "sess-1"
    let ipadDeviceId = "ipad-1"
    let devDeviceId  = "dev-1"
    let keyEpoch: UInt32 = 0
    let pairingCode: String

    /// 置 true 时，ServerHello 的 devSignature 用错误签名（负例：iPad 应拒绝）。
    var tamperDevSignature = false
    /// 置 true 时，ClientAuth 的 ipadSignature 用错误签名（负例：dev 应拒绝）。
    var tamperClientSignature = false

    init(pairingCode: String) { self.pairingCode = pairingCode }

    /// 执行完整四消息握手，返回两端建立的 SecureSession。
    func run(ipadPresentsCode: String) throws -> (ipad: SecureSession?, dev: SecureSession?) {
        // ---- 1. iPad 构造 ClientHello ----
        let clientNonce = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let hello = Handshake.makeClientHello(
            sessionId: sessionId,
            ipadDeviceId: ipadDeviceId,
            ipadIdentityPub: ipadIdentity.publicKey.rawRepresentation,
            ipadEphemeralPub: ipadEphemeral.publicKey.rawRepresentation,
            clientNonce: clientNonce,
            pairingCode: ipadPresentsCode
        )

        // ---- 2. dev 处理 ClientHello（先验 pairingCodeProof）并构造 ServerHello ----
        // dev 用自己持有的 pairingCode 重算校验（此处即真实 pairingCode）。
        var serverHello = try Handshake.makeServerHello(
            clientHello: hello,
            devDeviceId: devDeviceId,
            devIdentity: devIdentity,
            devEphemeralPub: devEphemeral.publicKey.rawRepresentation,
            serverNonce: Data((0..<32).map { _ in UInt8.random(in: 0...255) }),
            keyEpoch: keyEpoch,
            pairingCode: pairingCode
        )
        if tamperDevSignature {
            // 用无关密钥对垃圾数据签名，制造无效 devSignature。
            serverHello.devSignature = try Curve25519.Signing.PrivateKey()
                .signature(for: Data("garbage".utf8))
        }

        // ---- 3. iPad 验 devSignature（用配对得到的 dev 身份公钥）并构造 ClientAuth ----
        var clientAuth = try Handshake.verifyServerHelloAndMakeClientAuth(
            clientHello: hello,
            serverHello: serverHello,
            devIdentityPub: devIdentity.publicKey.rawRepresentation,   // 带外得到的 dev 身份公钥
            ipadIdentity: ipadIdentity
        )
        if tamperClientSignature {
            clientAuth.ipadSignature = try Curve25519.Signing.PrivateKey()
                .signature(for: Data("garbage".utf8))
        }

        // ---- 4. dev 验 ipadSignature 并 derive 密钥建 SecureSession ----
        let devSession = try Handshake.verifyClientAuthAndFinish(
            clientHello: hello,
            serverHello: serverHello,
            clientAuth: clientAuth,
            devEphemeral: devEphemeral
        )

        // iPad 侧：验 devSignature 通过后已可 derive，建 SecureSession。
        let ipadSession = try Handshake.finishClient(
            clientHello: hello,
            serverHello: serverHello,
            ipadEphemeral: ipadEphemeral
        )

        return (ipadSession, devSession)
    }
}

@Test func fullHandshakeMutualAuthSucceeds() throws {
    let h = HandshakeHarness(pairingCode: "PAIR-OK")
    let session = try h.run(ipadPresentsCode: "PAIR-OK")
    #expect(session.ipad != nil && session.dev != nil)
    let env = try session.ipad!.seal(Data("ping".utf8))
    #expect(try session.dev!.open(env) == Data("ping".utf8))
}

@Test func handshakeRejectsWrongPairingCode() throws {
    let h = HandshakeHarness(pairingCode: "PAIR-OK")
    #expect(throws: HandshakeError.pairingCodeMismatch) {
        _ = try h.run(ipadPresentsCode: "WRONG")
    }
}

@Test func handshakeRejectsBadDevSignature() throws {
    var h = HandshakeHarness(pairingCode: "PAIR-OK")
    h.tamperDevSignature = true
    #expect(throws: HandshakeError.badServerSignature) {
        _ = try h.run(ipadPresentsCode: "PAIR-OK")
    }
}

@Test func handshakeRejectsBadClientSignature() throws {
    var h = HandshakeHarness(pairingCode: "PAIR-OK")
    h.tamperClientSignature = true
    #expect(throws: HandshakeError.badClientSignature) {
        _ = try h.run(ipadPresentsCode: "PAIR-OK")
    }
}

/// 安全不变量 2：pairingCode 不明文过线——序列化 ClientHello 的字节里不含 code 本身，
/// 只带 HMAC proof。用有辨识度的 code 直接在 JSON 里搜。
@Test func pairingCodeNotOnWire() throws {
    let secret = "SECRET-PAIR-CODE-123"
    let hello = Handshake.makeClientHello(
        sessionId: "s",
        ipadDeviceId: "i",
        ipadIdentityPub: Data([1, 2, 3]),
        ipadEphemeralPub: Data([4, 5, 6]),
        clientNonce: Data((0..<32).map { _ in UInt8.random(in: 0...255) }),
        pairingCode: secret
    )
    let encoded = try JSONEncoder().encode(hello)
    let json = String(data: encoded, encoding: .utf8)!
    #expect(!json.contains(secret))              // 明文 code 不上线
    #expect(json.contains("pairingCodeProof"))   // 传的是 proof 字段
}

/// 安全不变量：协议版本不符时 dev 侧 makeServerHello 拒绝。
/// 直接单测该步——构造 protocolVersion 错误的 ClientHello 传入。
@Test func handshakeRejectsVersionMismatch() throws {
    var hello = Handshake.makeClientHello(
        sessionId: "s",
        ipadDeviceId: "i",
        ipadIdentityPub: Data([1, 2, 3]),
        ipadEphemeralPub: Data([4, 5, 6]),
        clientNonce: Data((0..<32).map { _ in UInt8.random(in: 0...255) }),
        pairingCode: "PAIR-OK"
    )
    hello.protocolVersion = "codexrelay-e2ee-v0"   // 与 RelayProtocolVersion.tag 不符
    #expect(throws: HandshakeError.versionMismatch) {
        _ = try Handshake.makeServerHello(
            clientHello: hello,
            devDeviceId: "d",
            devIdentity: Curve25519.Signing.PrivateKey(),
            devEphemeralPub: Data([7, 8, 9]),
            serverNonce: Data((0..<32).map { _ in UInt8.random(in: 0...255) }),
            keyEpoch: 0,
            pairingCode: "PAIR-OK"
        )
    }
}
