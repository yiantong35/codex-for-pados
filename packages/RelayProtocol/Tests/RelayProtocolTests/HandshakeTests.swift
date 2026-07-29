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

        // iPad 侧：finishClient 内部会重新验 devSignature（认证 by-construction）。
        let ipadSession = try Handshake.finishClient(
            clientHello: hello,
            serverHello: serverHello,
            ipadEphemeral: ipadEphemeral,
            devIdentityPub: devIdentity.publicKey.rawRepresentation   // 带外得到的 dev 身份公钥
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

/// M1 回归：echoedClientNonce 必须被显式校验（此前设而不验）。
/// 篡改 echoedClientNonce（≠ clientHello.clientNonce）时 iPad 应拒绝。
@Test func mismatchedEchoedClientNonceRejected() throws {
    let ipadIdentity = Curve25519.Signing.PrivateKey()
    let devIdentity  = Curve25519.Signing.PrivateKey()
    let ipadEphemeral = Curve25519.KeyAgreement.PrivateKey()
    let devEphemeral  = Curve25519.KeyAgreement.PrivateKey()
    let pairingCode = "PAIR-OK"

    let clientNonce = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
    let hello = Handshake.makeClientHello(
        sessionId: "sess-1", ipadDeviceId: "ipad-1",
        ipadIdentityPub: ipadIdentity.publicKey.rawRepresentation,
        ipadEphemeralPub: ipadEphemeral.publicKey.rawRepresentation,
        clientNonce: clientNonce, pairingCode: pairingCode)
    var serverHello = try Handshake.makeServerHello(
        clientHello: hello, devDeviceId: "dev-1", devIdentity: devIdentity,
        devEphemeralPub: devEphemeral.publicKey.rawRepresentation,
        serverNonce: Data((0..<32).map { _ in UInt8.random(in: 0...255) }),
        keyEpoch: 0, pairingCode: pairingCode)
    serverHello.echoedClientNonce = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
    #expect(throws: HandshakeError.badServerSignature) {
        _ = try Handshake.verifyServerHelloAndMakeClientAuth(
            clientHello: hello, serverHello: serverHello,
            devIdentityPub: devIdentity.publicKey.rawRepresentation,
            ipadIdentity: ipadIdentity)
    }
}

/// I2 回归：deviceId 必须进签名 transcript，被 devSignature 双向覆盖。
/// 篡改已签名 ServerHello 的 devDeviceId 后，iPad 验签必须失败（MITM 篡改 deviceId 被检测）。
@Test func tamperedDevDeviceIdRejected() throws {
    let ipadIdentity = Curve25519.Signing.PrivateKey()
    let devIdentity  = Curve25519.Signing.PrivateKey()
    let ipadEphemeral = Curve25519.KeyAgreement.PrivateKey()
    let devEphemeral  = Curve25519.KeyAgreement.PrivateKey()
    let pairingCode = "PAIR-OK"

    let clientNonce = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
    let hello = Handshake.makeClientHello(
        sessionId: "sess-1", ipadDeviceId: "ipad-1",
        ipadIdentityPub: ipadIdentity.publicKey.rawRepresentation,
        ipadEphemeralPub: ipadEphemeral.publicKey.rawRepresentation,
        clientNonce: clientNonce, pairingCode: pairingCode)
    var serverHello = try Handshake.makeServerHello(
        clientHello: hello, devDeviceId: "dev-1", devIdentity: devIdentity,
        devEphemeralPub: devEphemeral.publicKey.rawRepresentation,
        serverNonce: Data((0..<32).map { _ in UInt8.random(in: 0...255) }),
        keyEpoch: 0, pairingCode: pairingCode)
    serverHello.devDeviceId = "attacker-dev"   // MITM 篡改 deviceId（签名不变）
    #expect(throws: HandshakeError.badServerSignature) {
        _ = try Handshake.verifyServerHelloAndMakeClientAuth(
            clientHello: hello, serverHello: serverHello,
            devIdentityPub: devIdentity.publicKey.rawRepresentation,
            ipadIdentity: ipadIdentity)
    }
}

/// I1 回归：即便调用方漏了步骤 3 的验签，finishClient 也必须在建 session 前
/// 自行验 devSignature。给它一个错误的 devIdentityPub（冒充开发机场景），期望抛 badServerSignature。
/// 这条测试封死“漏调验签直接 finishClient 与任意冒充开发机建通道”的认证绕过路径。
@Test func finishClientRejectsForgedDevIdentity() throws {
    let ipadIdentity = Curve25519.Signing.PrivateKey()
    let devIdentity  = Curve25519.Signing.PrivateKey()
    let ipadEphemeral = Curve25519.KeyAgreement.PrivateKey()
    let devEphemeral  = Curve25519.KeyAgreement.PrivateKey()
    let pairingCode = "PAIR-OK"

    let clientNonce = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
    let hello = Handshake.makeClientHello(
        sessionId: "sess-1",
        ipadDeviceId: "ipad-1",
        ipadIdentityPub: ipadIdentity.publicKey.rawRepresentation,
        ipadEphemeralPub: ipadEphemeral.publicKey.rawRepresentation,
        clientNonce: clientNonce,
        pairingCode: pairingCode
    )
    let serverHello = try Handshake.makeServerHello(
        clientHello: hello,
        devDeviceId: "dev-1",
        devIdentity: devIdentity,
        devEphemeralPub: devEphemeral.publicKey.rawRepresentation,
        serverNonce: Data((0..<32).map { _ in UInt8.random(in: 0...255) }),
        keyEpoch: 0,
        pairingCode: pairingCode
    )
    // 传入攻击者的公钥（≠ 真正签名的 devIdentity），模拟漏调步骤 3 直接收尾。
    let attacker = Curve25519.Signing.PrivateKey()
    #expect(throws: HandshakeError.badServerSignature) {
        _ = try Handshake.finishClient(
            clientHello: hello,
            serverHello: serverHello,
            ipadEphemeral: ipadEphemeral,
            devIdentityPub: attacker.publicKey.rawRepresentation
        )
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

/// RejectHello 过线消息：round-trip 编解码保真，且 kind tag 固定为 "reject"。
@Test func rejectHelloRoundTrip() throws {
    let r = RejectHello(sessionId: "sid-1", reason: .trustRevoked)
    let data = try JSONEncoder().encode(r)
    let back = try JSONDecoder().decode(RejectHello.self, from: data)
    #expect(back == r)
    #expect(back.reason == .trustRevoked)
    #expect(back.kind == "reject")
}

/// ServerHello 无 kind 字段：iPad 侧靠该字段做类型判别，
/// 把 ServerHello 的编码按 RejectHello 解应失败（缺 required 字段）。
@Test func serverHelloNotDecodableAsRejectHello() throws {
    let sh = ServerHello(devDeviceId: "d", devIdentityPub: Data([1]), devEphemeralPub: Data([2]),
                         serverNonce: Data([3]), keyEpoch: 0, echoedClientNonce: Data([4]), devSignature: Data([5]))
    let shData = try JSONEncoder().encode(sh)
    #expect((try? JSONDecoder().decode(RejectHello.self, from: shData)) == nil)
}

/// 受信任复连：iPad 身份已在 dev 信任列表内，走 makeServerHelloTrusted 免一次性 pairingCode
/// （proof 留空），但 Ed25519 双向验签一步不省——仍能建立完整双向认证会话。
/// 证明「免 proof 但验签不省」。
@Test func trustedReconnectSkipsProofButStillMutualAuth() throws {
    let ipadIdentity = Curve25519.Signing.PrivateKey()
    let devIdentity  = Curve25519.Signing.PrivateKey()
    let ipadEphemeral = Curve25519.KeyAgreement.PrivateKey()
    let devEphemeral  = Curve25519.KeyAgreement.PrivateKey()

    let clientNonce = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
    // 受信任复连：ClientHello 的 pairingCodeProof 留空（不带一次性口令证明）。
    var hello = Handshake.makeClientHello(
        sessionId: "sess-1", ipadDeviceId: "ipad-1",
        ipadIdentityPub: ipadIdentity.publicKey.rawRepresentation,
        ipadEphemeralPub: ipadEphemeral.publicKey.rawRepresentation,
        clientNonce: clientNonce, pairingCode: "unused")
    hello.pairingCodeProof = Data()   // 复连免 proof

    // dev 走 trusted 分支：不验 proof，其余（版本、组包、签 transcript）一致。
    let serverHello = try Handshake.makeServerHelloTrusted(
        clientHello: hello, devDeviceId: "dev-1", devIdentity: devIdentity,
        devEphemeralPub: devEphemeral.publicKey.rawRepresentation,
        serverNonce: Data((0..<32).map { _ in UInt8.random(in: 0...255) }),
        keyEpoch: 0)

    // iPad 验 devSignature 并造 ClientAuth（验签不省）。
    let clientAuth = try Handshake.verifyServerHelloAndMakeClientAuth(
        clientHello: hello, serverHello: serverHello,
        devIdentityPub: devIdentity.publicKey.rawRepresentation, ipadIdentity: ipadIdentity)
    // dev 验 ipadSignature 并建 session（验签不省）。
    let devSession = try Handshake.verifyClientAuthAndFinish(
        clientHello: hello, serverHello: serverHello, clientAuth: clientAuth,
        devEphemeral: devEphemeral)
    let ipadSession = try Handshake.finishClient(
        clientHello: hello, serverHello: serverHello,
        ipadEphemeral: ipadEphemeral, devIdentityPub: devIdentity.publicKey.rawRepresentation)

    // 双向认证会话建立成功且加密通道可用。
    let env = try ipadSession.seal(Data("ping".utf8))
    #expect(try devSession.open(env) == Data("ping".utf8))
}

/// 防降级：未受信任路径（原 makeServerHello）遇空 pairingCodeProof 仍必抛 pairingCodeMismatch，
/// 不被绕过——受信任免 proof 只走 trusted 专用函数。
@Test func makeServerHelloRejectsEmptyProof() throws {
    let ipadIdentity = Curve25519.Signing.PrivateKey()
    let ipadEphemeral = Curve25519.KeyAgreement.PrivateKey()
    let clientNonce = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
    var hello = Handshake.makeClientHello(
        sessionId: "sess-1", ipadDeviceId: "ipad-1",
        ipadIdentityPub: ipadIdentity.publicKey.rawRepresentation,
        ipadEphemeralPub: ipadEphemeral.publicKey.rawRepresentation,
        clientNonce: clientNonce, pairingCode: "PAIR-OK")
    hello.pairingCodeProof = Data()   // 空 proof
    #expect(throws: HandshakeError.pairingCodeMismatch) {
        _ = try Handshake.makeServerHello(
            clientHello: hello, devDeviceId: "dev-1",
            devIdentity: Curve25519.Signing.PrivateKey(),
            devEphemeralPub: Data((0..<32).map { _ in UInt8.random(in: 0...255) }),
            serverNonce: Data((0..<32).map { _ in UInt8.random(in: 0...255) }),
            keyEpoch: 0, pairingCode: "PAIR-OK")
    }
}

/// F1（P0）：pairingCodeProof MUST 绑定整条 ClientHello（除 proof 自身外全字段）。
/// 攻击者复用一条合法 ClientHello 的 clientNonce + pairingCodeProof，但替换
/// ipadIdentityPub / ipadEphemeralPub / ipadDeviceId 任意一项 → dev 侧 makeServerHello
/// 以完整 ClientHello 重算 proof 必失配 → 抛 pairingCodeMismatch（杜绝替换公钥认证绕过）。
/// 合法未篡改的 ClientHello 仍正常通过（回归护栏，改前改后都应绿）。
@Test func pairingProofBoundToFullClientHelloRejectsKeySubstitution() throws {
    let pairingCode = "123456"
    let ipadIdentity = Curve25519.Signing.PrivateKey()
    let ipadEph = Curve25519.KeyAgreement.PrivateKey()
    let clientNonce = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
    let legit = Handshake.makeClientHello(
        sessionId: "s-1", ipadDeviceId: "ipad-A",
        ipadIdentityPub: ipadIdentity.publicKey.rawRepresentation,
        ipadEphemeralPub: ipadEph.publicKey.rawRepresentation,
        clientNonce: clientNonce, pairingCode: pairingCode)

    let devIdentity = Curve25519.Signing.PrivateKey()
    let devEph = Curve25519.KeyAgreement.PrivateKey()
    let serverNonce = Data((0..<16).map { _ in UInt8.random(in: 0...255) })

    // 攻击者的替换材料
    let attackerIdentity = Curve25519.Signing.PrivateKey()
    let attackerEph = Curve25519.KeyAgreement.PrivateKey()

    func makeServer(_ h: ClientHello) throws -> ServerHello {
        try Handshake.makeServerHello(
            clientHello: h, devDeviceId: "dev-1", devIdentity: devIdentity,
            devEphemeralPub: devEph.publicKey.rawRepresentation,
            serverNonce: serverNonce, keyEpoch: 1, pairingCode: pairingCode)
    }

    // (a) 替换 ipadIdentityPub，复用合法 nonce+proof
    var tamperedIdentity = legit
    tamperedIdentity.ipadIdentityPub = attackerIdentity.publicKey.rawRepresentation
    #expect(throws: HandshakeError.pairingCodeMismatch) { _ = try makeServer(tamperedIdentity) }

    // (b) 替换 ipadEphemeralPub
    var tamperedEph = legit
    tamperedEph.ipadEphemeralPub = attackerEph.publicKey.rawRepresentation
    #expect(throws: HandshakeError.pairingCodeMismatch) { _ = try makeServer(tamperedEph) }

    // (c) 替换 ipadDeviceId
    var tamperedId = legit
    tamperedId.ipadDeviceId = "ipad-EVIL"
    #expect(throws: HandshakeError.pairingCodeMismatch) { _ = try makeServer(tamperedId) }

    // 合法未篡改仍通过（回归护栏）
    #expect(throws: Never.self) { _ = try makeServer(legit) }
}

/// F1 顺序护栏：makeServerHello 的版本校验 MUST 先于 proof 校验——混版端得干净的
/// versionMismatch，而非误导性 pairingCodeMismatch（即便 proof 因版本进编码也随之失配）。
@Test func versionMismatchTakesPrecedenceOverProof() throws {
    let ipadIdentity = Curve25519.Signing.PrivateKey()
    let ipadEph = Curve25519.KeyAgreement.PrivateKey()
    let clientNonce = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
    var hello = Handshake.makeClientHello(
        sessionId: "s-1", ipadDeviceId: "ipad-A",
        ipadIdentityPub: ipadIdentity.publicKey.rawRepresentation,
        ipadEphemeralPub: ipadEph.publicKey.rawRepresentation,
        clientNonce: clientNonce, pairingCode: "PAIR-OK")
    hello.protocolVersion = "codexrelay-e2ee-v1"   // 旧版本：与当前 tag(v2) 不符
    #expect(throws: HandshakeError.versionMismatch) {
        _ = try Handshake.makeServerHello(
            clientHello: hello, devDeviceId: "dev-1",
            devIdentity: Curve25519.Signing.PrivateKey(),
            devEphemeralPub: Data((0..<16).map { _ in UInt8.random(in: 0...255) }),
            serverNonce: Data((0..<16).map { _ in UInt8.random(in: 0...255) }),
            keyEpoch: 1, pairingCode: "PAIR-OK")
    }
}

/// SecureReady（消息 4）附加 stableSessionId 字段：dev 建 SecureSession 后回传该 iPad 的稳定
/// sessionId，供 iPad 首次配对消费并持久化用于后续复连直连。round-trip 编解码保真。
@Test func secureReadyCarriesStableSessionId() throws {
    let sr = SecureReady(sessionId: "sid-room", keyEpoch: 0, devDeviceId: "dev-1", stableSessionId: "stable-abc")
    let data = try JSONEncoder().encode(sr)
    let back = try JSONDecoder().decode(SecureReady.self, from: data)
    #expect(back.stableSessionId == "stable-abc")
    #expect(back == sr)
}
