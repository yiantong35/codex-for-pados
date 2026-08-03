import Testing
import Foundation
import Crypto
import RelayProtocol
@testable import RelayServerCore

/// 本地假 relay 三端对接集成测：把「iPad 侧 SecureSession ↔ 内存 RelayRooms 撮合转发 ↔ dev 侧 SecureSession」
/// 串成一次完整往返，证明端到端加解密 + 撮合转发链路本地可行（不上 ECS、不起真 NIO ws）。
///
/// 三端角色：
/// - iPad 侧 SecureSession + dev 侧 SecureSession：由 RelayProtocol 四消息握手建立（双向认证通过）。
/// - RelayRooms：内存假 relay，按 sessionId 撮合两端 sink，纯密文透传，不解析 frame。
///
/// HandshakeTests.swift 里的 HandshakeHarness 是 `private` 且属于 RelayProtocolTests target，
/// 无法跨 target 复用，这里在集成测内自建同一条四消息握手序列。

/// 跑完 iPad↔dev 四消息握手，返回两端建立好的 SecureSession（等价于 HandshakeTests 里的 HandshakeHarness）。
private func makeHandshakePair(sessionId: String, pairingCode: String) throws -> (ipad: SecureSession, dev: SecureSession) {
    let ipadIdentity  = Curve25519.Signing.PrivateKey()
    let devIdentity   = Curve25519.Signing.PrivateKey()
    let ipadEphemeral = Curve25519.KeyAgreement.PrivateKey()
    let devEphemeral  = Curve25519.KeyAgreement.PrivateKey()

    // 1. iPad -> ClientHello
    let clientNonce = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
    let hello = Handshake.makeClientHello(
        sessionId: sessionId,
        ipadDeviceId: "ipad-1",
        ipadIdentityPub: ipadIdentity.publicKey.rawRepresentation,
        ipadEphemeralPub: ipadEphemeral.publicKey.rawRepresentation,
        clientNonce: clientNonce,
        pairingCode: pairingCode
    )

    // 2. dev -> ServerHello（验 pairingCodeProof + 签名）
    let serverHello = try Handshake.makeServerHello(
        clientHello: hello,
        devDeviceId: "dev-1",
        devIdentity: devIdentity,
        devEphemeralPub: devEphemeral.publicKey.rawRepresentation,
        serverNonce: Data((0..<32).map { _ in UInt8.random(in: 0...255) }),
        keyEpoch: 0,
        pairingCode: pairingCode
    )

    // 3. iPad 验 devSignature（用带外拿到的 dev 身份公钥）-> ClientAuth
    let clientAuth = try Handshake.verifyServerHelloAndMakeClientAuth(
        clientHello: hello,
        serverHello: serverHello,
        devIdentityPub: devIdentity.publicKey.rawRepresentation,
        ipadIdentity: ipadIdentity
    )

    // 4. dev 验 ipadSignature -> derive 密钥建 SecureSession
    let devSession = try Handshake.verifyClientAuthAndFinish(
        clientHello: hello,
        serverHello: serverHello,
        clientAuth: clientAuth,
        devEphemeral: devEphemeral
    )
    // iPad 侧收尾建 SecureSession（内部重验 devSignature）
    let ipadSession = try Handshake.finishClient(
        clientHello: hello,
        serverHello: serverHello,
        ipadEphemeral: ipadEphemeral,
        devIdentityPub: devIdentity.publicKey.rawRepresentation
    )
    return (ipadSession, devSession)
}

/// 假 relay 三端往返：iPad seal -> encoded -> rooms.forward -> dev sink -> open，反向亦然。
/// 断言双向明文完整解回，且 relay 转发的 frame 字符串不含明文（零知识）。
@Test func localFakeRelayThreePartyRoundTrip() throws {
    let sessionId = "sess-e2e"
    let (ipadSession, devSession) = try makeHandshakePair(sessionId: sessionId, pairingCode: "PAIR-OK")

    // 假 relay：内存 RelayRooms，两端各注册 sink。
    // sink 收到对端转来的密文字符串后，转回 SecureEnvelope 喂给本侧 open。
    let rooms = RelayRooms()

    var devReceived: [String] = []   // dev 侧解出的明文
    var ipadReceived: [String] = []  // iPad 侧解出的明文
    var forwardedFrames: [String] = [] // relay 实际透传过的 frame（用于零知识断言）

    // dev 侧 sink：收 iPad 发来的密文 frame，解密。
    rooms.join(sessionId: sessionId, role: .devMachine) { frame in
        forwardedFrames.append(frame)
        let env = try! SecureEnvelope(decoding: Data(frame.utf8))
        let pt = try! devSession.open(env)
        devReceived.append(String(decoding: pt, as: UTF8.self))
    }
    // iPad 侧 sink：收 dev 发来的密文 frame，解密。
    rooms.join(sessionId: sessionId, role: .iPad) { frame in
        forwardedFrames.append(frame)
        let env = try! SecureEnvelope(decoding: Data(frame.utf8))
        let pt = try! ipadSession.open(env)
        ipadReceived.append(String(decoding: pt, as: UTF8.self))
    }

    // ---- 正向：iPad -> relay -> dev ----
    let requestText = "initialize request"
    let reqEnv = try ipadSession.seal(Data(requestText.utf8), kind: .appData)
    let reqFrame = String(decoding: try reqEnv.encoded(), as: UTF8.self)
    rooms.forward(sessionId: sessionId, from: .iPad, frame: reqFrame)
    #expect(devReceived == [requestText])

    // ---- 反向：dev -> relay -> iPad ----
    let responseText = "initialize response"
    let respEnv = try devSession.seal(Data(responseText.utf8), kind: .appData)
    let respFrame = String(decoding: try respEnv.encoded(), as: UTF8.self)
    rooms.forward(sessionId: sessionId, from: .devMachine, frame: respFrame)
    #expect(ipadReceived == [responseText])

    // ---- 零知识：relay 透传的 frame 里不含任何明文 ----
    #expect(!forwardedFrames.isEmpty)
    for frame in forwardedFrames {
        #expect(!frame.contains(requestText))
        #expect(!frame.contains(responseText))
    }
}
