import Testing
import Foundation
import Crypto
import RelayProtocol
@testable import RelayDialoutCore

/// 驱动 DialoutContext 走完一次真实的四消息握手（在内存中模拟 iPad 侧），
/// 验证 Task 2.2/2.3：首次配对自动记信任 + 稳定 sessionId 生成/复用 + 加密回传 SecureReady。
private struct DialoutTrustHarness {
    let devDir: URL
    let trustDir: URL
    let devKeyStore: DevKeyStore
    let devDeviceId = "dev-1"
    let pairingCode = "PAIR-OK"
    let expiresAt = Int64(Date().timeIntervalSince1970) + 600

    // iPad 侧身份/交换密钥（模拟单台 iPad，跨多次配对保持不变以验证 stableSessionId 复用）。
    let ipadIdentity: Curve25519.Signing.PrivateKey
    let ipadEphemeral: Curve25519.KeyAgreement.PrivateKey

    init(ipadIdentity: Curve25519.Signing.PrivateKey = Curve25519.Signing.PrivateKey(),
         ipadEphemeral: Curve25519.KeyAgreement.PrivateKey = Curve25519.KeyAgreement.PrivateKey()) throws {
        self.devDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        self.trustDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        self.devKeyStore = try DevKeyStore(dir: devDir)
        self.ipadIdentity = ipadIdentity
        self.ipadEphemeral = ipadEphemeral
    }

    var ipadPubB64: String { ipadIdentity.publicKey.rawRepresentation.base64EncodedString() }

    /// 用给定的 TrustStore 造一个 DialoutContext 并走完握手；返回加密回传帧 + iPad 侧 session。
    func runHandshake(trust: TrustStore, sessionId: String) throws -> (readyFrame: Data, ipadSession: SecureSession) {
        let context = DialoutContext(keyStore: devKeyStore, devDeviceId: devDeviceId,
                                     pairingCode: pairingCode, expiresAt: expiresAt, trust: trust)
        // 1. iPad → ClientHello
        let clientNonce = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let hello = Handshake.makeClientHello(
            sessionId: sessionId, ipadDeviceId: "ipad-1",
            ipadIdentityPub: ipadIdentity.publicKey.rawRepresentation,
            ipadEphemeralPub: ipadEphemeral.publicKey.rawRepresentation,
            clientNonce: clientNonce, pairingCode: pairingCode)
        // 2. dev 处理 ClientHello → ServerHello
        let serverHelloData = try context.handleClientHello(JSONEncoder().encode(hello))
        let serverHello = try JSONDecoder().decode(ServerHello.self, from: serverHelloData)
        // 3. iPad 验 devSignature 并造 ClientAuth + 建 iPad 侧 session
        let clientAuth = try Handshake.verifyServerHelloAndMakeClientAuth(
            clientHello: hello, serverHello: serverHello,
            devIdentityPub: devKeyStore.identityPublicKeyRaw, ipadIdentity: ipadIdentity)
        let ipadSession = try Handshake.finishClient(
            clientHello: hello, serverHello: serverHello,
            ipadEphemeral: ipadEphemeral, devIdentityPub: devKeyStore.identityPublicKeyRaw)
        // 4. dev 验 ClientAuth → 记信任 + 加密回传 SecureReady
        let readyFrame = try context.handleClientAuth(JSONEncoder().encode(clientAuth))
        return (readyFrame, ipadSession)
    }
}

@Test func firstPairingRecordsTrustWithStableSessionId() throws {
    let h = try DialoutTrustHarness()
    let trust = try TrustStore(dir: h.trustDir)
    _ = try h.runHandshake(trust: trust, sessionId: "room-1")

    let rec = trust.record(forPubB64: h.ipadPubB64)
    #expect(rec != nil)
    let stable = rec?.stableSessionId ?? ""
    #expect(!stable.isEmpty)
}

@Test func handleClientAuthReturnsEncryptedSecureReady() throws {
    let h = try DialoutTrustHarness()
    let trust = try TrustStore(dir: h.trustDir)
    let (frame, ipadSession) = try h.runHandshake(trust: trust, sessionId: "room-1")

    // 回传帧必须是加密 SecureEnvelope（不明文过 relay），iPad 侧用自己 session 解开。
    let env = try SecureEnvelope(decoding: frame)
    let plaintext = try ipadSession.open(env)
    let ready = try JSONDecoder().decode(SecureReady.self, from: plaintext)

    let stable = trust.record(forPubB64: h.ipadPubB64)?.stableSessionId
    #expect(ready.stableSessionId == stable)
    #expect(ready.sessionId == "room-1")
    #expect(ready.devDeviceId == h.devDeviceId)
}

@Test func repeatedPairingReusesSameStableSessionId() throws {
    let h = try DialoutTrustHarness()
    // 第一次配对：新 TrustStore。
    let trust1 = try TrustStore(dir: h.trustDir)
    _ = try h.runHandshake(trust: trust1, sessionId: "room-1")
    let firstStable = trust1.record(forPubB64: h.ipadPubB64)?.stableSessionId
    #expect(!(firstStable?.isEmpty ?? true))

    // 同一 iPad 再次配对：从磁盘重载 TrustStore + 新 DialoutContext，应复用同一 stableSessionId。
    let trust2 = try TrustStore(dir: h.trustDir)
    let (frame, ipadSession) = try h.runHandshake(trust: trust2, sessionId: "room-2")
    let secondStable = trust2.record(forPubB64: h.ipadPubB64)?.stableSessionId
    #expect(secondStable == firstStable)
    #expect(trust2.all().count == 1)   // 幂等，不新增记录

    // 回传帧里的 stableSessionId 也应是复用后的稳定值。
    let ready = try JSONDecoder().decode(
        SecureReady.self, from: try ipadSession.open(try SecureEnvelope(decoding: frame)))
    #expect(ready.stableSessionId == firstStable)
}
