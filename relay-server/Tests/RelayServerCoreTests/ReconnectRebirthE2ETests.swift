import Testing
import Foundation
import Crypto
import RelayProtocol
@testable import RelayServerCore

/// 缺陷 #1 端到端场景（A7）：iPad 单边断线 → dev dialout 常驻 → iPad 重生 ephemeral/session。
///
/// 把 A1–A6 的效果在假 relay 集成层串成一条链，聚焦「重连后仍能通」这一端到端可观察行为：
/// 1. iPad+dev 握手建 session#1，双向往返正常。
/// 2. iPad 单边断线（leave）；dev 常驻不退，其间 dev 发帧 → 因 iPad 缺席入 `pendingForIpad` 缓冲。
///    这些帧是 dev 用**旧会话密钥**(session#1)seal 的密文——iPad 重生后 ephemeral 已换、必然解不开。
/// 3. iPad 重连：走一次**新握手**建 session#2（新 ephemeral / 新对称密钥），重新 join。
/// 4. #2 不对称 reset-on-rejoin：join(.iPad) 丢弃 stale `pendingForIpad`，绝不把旧密钥密文投给新 iPad。
/// 5. dev 用 session#2 重新 seal ���帧 → 转发 → iPad 用 session#2 成功解回。链路在重连后恢复。
///
/// 与 LocalE2EIntegrationTests 同法自建四消息握手（HandshakeHarness 跨 target 不可复用）。
private func makeReconnectHandshakePair(sessionId: String, pairingCode: String)
    throws -> (ipad: SecureSession, dev: SecureSession) {
    let ipadIdentity  = Curve25519.Signing.PrivateKey()
    let devIdentity   = Curve25519.Signing.PrivateKey()
    let ipadEphemeral = Curve25519.KeyAgreement.PrivateKey()
    let devEphemeral  = Curve25519.KeyAgreement.PrivateKey()

    let clientNonce = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
    let hello = Handshake.makeClientHello(
        sessionId: sessionId, ipadDeviceId: "ipad-1",
        ipadIdentityPub: ipadIdentity.publicKey.rawRepresentation,
        ipadEphemeralPub: ipadEphemeral.publicKey.rawRepresentation,
        clientNonce: clientNonce, pairingCode: pairingCode)
    let serverHello = try Handshake.makeServerHello(
        clientHello: hello, devDeviceId: "dev-1", devIdentity: devIdentity,
        devEphemeralPub: devEphemeral.publicKey.rawRepresentation,
        serverNonce: Data((0..<32).map { _ in UInt8.random(in: 0...255) }),
        keyEpoch: 0, pairingCode: pairingCode)
    let clientAuth = try Handshake.verifyServerHelloAndMakeClientAuth(
        clientHello: hello, serverHello: serverHello,
        devIdentityPub: devIdentity.publicKey.rawRepresentation, ipadIdentity: ipadIdentity)
    let devSession = try Handshake.verifyClientAuthAndFinish(
        clientHello: hello, serverHello: serverHello, clientAuth: clientAuth, devEphemeral: devEphemeral)
    let ipadSession = try Handshake.finishClient(
        clientHello: hello, serverHello: serverHello,
        ipadEphemeral: ipadEphemeral, devIdentityPub: devIdentity.publicKey.rawRepresentation)
    return (ipadSession, devSession)
}

@Test func ipadReconnectRebirthRecoversEndToEnd() throws {
    let sessionId = "sess-reconnect"
    let rooms = RelayRooms()

    // ---- 阶段 1：握手 #1 + dev 常驻 join + iPad 首次 join，双向往返正常 ----
    let (ipadSession1, devSession1) = try makeReconnectHandshakePair(sessionId: sessionId, pairingCode: "PAIR-OK")

    var devReceived: [String] = []
    var ipadReceived: [String] = []
    var forwardedFrames: [String] = []

    // dev 常驻 sink（整个场景不退出）。真实 dev 侧对连接层信令(peer-left)静默忽略，不当密文解。
    let devJoin = rooms.join(sessionId: sessionId, role: .devMachine) { frame in
        forwardedFrames.append(frame)
        if let sig = try? RelaySignal(decoding: Data(frame.utf8)), sig.kind == RelaySignal.peerLeftKind { return }
        let env = try! SecureEnvelope(decoding: Data(frame.utf8))
        devReceived.append(String(decoding: try! devSession1.open(env), as: UTF8.self))
    }
    guard case .joined = devJoin else { Issue.record("dev join 应成功"); return }

    // iPad 首次 join（session#1）。
    let ipadJoin1 = rooms.join(sessionId: sessionId, role: .iPad) { frame in
        forwardedFrames.append(frame)
        let env = try! SecureEnvelope(decoding: Data(frame.utf8))
        ipadReceived.append(String(decoding: try! ipadSession1.open(env), as: UTF8.self))
    }
    guard case .joined(let ipadConn1) = ipadJoin1 else { Issue.record("iPad 首次 join 应成功"); return }

    // 正向 + 反向各一帧，确认 session#1 链路通。
    let req1 = "initialize"
    rooms.forward(sessionId: sessionId, from: .iPad,
                  frame: String(decoding: try ipadSession1.seal(Data(req1.utf8), kind: .appData).encoded(), as: UTF8.self))
    #expect(devReceived == [req1])
    let resp1 = "initialized ok"
    rooms.forward(sessionId: sessionId, from: .devMachine,
                  frame: String(decoding: try devSession1.seal(Data(resp1.utf8), kind: .appData).encoded(), as: UTF8.self))
    #expect(ipadReceived == [resp1])

    // ---- 阶段 2：iPad 单边断线；dev 常驻期间发帧 → 入 pendingForIpad（stale 旧密钥密文）----
    rooms.leave(sessionId: sessionId, role: .iPad, connId: ipadConn1)
    let staleText = "stale-old-key-frame"
    let staleFrame = String(decoding: try devSession1.seal(Data(staleText.utf8), kind: .appData).encoded(), as: UTF8.self)
    rooms.forward(sessionId: sessionId, from: .devMachine, frame: staleFrame)   // iPad 缺席 → 缓冲

    // ---- 阶段 3+4：iPad 重生 session#2 重新 join；#2 丢弃 stale 缓冲，绝不投旧密钥密文给新 iPad ----
    let (ipadSession2, devSession2) = try makeReconnectHandshakePair(sessionId: sessionId, pairingCode: "PAIR-OK")
    var ipad2Received: [String] = []
    let ipadJoin2 = rooms.join(sessionId: sessionId, role: .iPad) { frame in
        forwardedFrames.append(frame)
        let env = try! SecureEnvelope(decoding: Data(frame.utf8))
        // 用 session#2 解；若 server 误 flush 了 stale 帧，这里会因解不开而 crash（try!）——即回归红线。
        ipad2Received.append(String(decoding: try! ipadSession2.open(env), as: UTF8.self))
    }
    guard case .joined = ipadJoin2 else { Issue.record("iPad 重连 join 应成功"); return }
    // 关键断言：rejoin 未投递任何缓冲帧（stale pendingForIpad 已被丢弃）。
    #expect(ipad2Received.isEmpty)

    // ---- 阶段 5：dev 用 session#2 重新 seal 发帧 → 转发 → iPad session#2 成功解回，链路恢复 ----
    let resp2 = "post-reconnect response"
    rooms.forward(sessionId: sessionId, from: .devMachine,
                  frame: String(decoding: try devSession2.seal(Data(resp2.utf8), kind: .appData).encoded(), as: UTF8.self))
    #expect(ipad2Received == [resp2])

    // 反向恢复由 A3/A4（dev 侧连接内重握手换 session）单测覆盖；本 harness dev 常驻 sink 仍绑 session#1，
    // 不重复建模 dev 换钥，聚焦「iPad 重生 + stale 丢弃 + 新密钥前向恢复」。

    // ---- 零知识：relay 透传帧不含任何明文 ----
    #expect(!forwardedFrames.isEmpty)
    for frame in forwardedFrames {
        #expect(!frame.contains(req1)); #expect(!frame.contains(resp1))
        #expect(!frame.contains(staleText)); #expect(!frame.contains(resp2))
    }
}
