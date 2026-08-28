import Testing
import Foundation
import Crypto
import RelayProtocol
@testable import RelayDialoutCore

// 前向保密（D1）：dev X25519 交换密钥每会话新生成，绝不持久化/跨握手复用。
//
// 复用 DialoutContextTrustTests.swift 里已验证的 iPad 侧握手构造方式（Handshake.makeClientHello /
// verifyServerHelloAndMakeClientAuth / finishClient），不新造重复实现。

/// 走一次「iPad → ClientHello，dev handleClientHello」，返回 ServerHello 里的 dev 交换公钥。
/// 每次调用都用新的 DialoutContext + 新 iPad 身份/临时密钥，模拟一次独立握手。
private func devEphemeralPubForOneHandshake(keyStore: DevKeyStore, pairingCode: String) throws -> Data {
    let trust = try TrustStore(dir: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let ctx = DialoutContext(keyStore: keyStore, devDeviceId: "dev", sessionId: "room",
                             pairingCode: pairingCode, expiresAt: Int64.max, trust: trust)
    let ipadIdentity = Curve25519.Signing.PrivateKey()
    let ipadEphemeral = Curve25519.KeyAgreement.PrivateKey()
    let hello = Handshake.makeClientHello(
        sessionId: "room", ipadDeviceId: "ipad-1",
        ipadIdentityPub: ipadIdentity.publicKey.rawRepresentation,
        ipadEphemeralPub: ipadEphemeral.publicKey.rawRepresentation,
        clientNonce: Data((0..<32).map { _ in UInt8.random(in: 0...255) }),
        pairingCode: pairingCode)
    let shData = try ctx.handleClientHello(JSONEncoder().encode(hello))
    return try JSONDecoder().decode(ServerHello.self, from: shData).devEphemeralPub
}

@Test func devEphemeralDiffersAcrossTwoHandshakes() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let keyStore = try DevKeyStore(dir: dir)   // 身份复用（同一 keyStore）

    let e1 = try devEphemeralPubForOneHandshake(keyStore: keyStore, pairingCode: "code-1")
    let e2 = try devEphemeralPubForOneHandshake(keyStore: keyStore, pairingCode: "code-2")
    #expect(e1 != e2)   // 两次握手 dev 交换公钥不同（每会话新生）
}

@Test func devEphemeralDiffersAcrossProcessRestart() throws {
    // 模拟进程重启：同一磁盘 dir 重建 DevKeyStore（身份复用），交换 eph 仍必须不同。
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }

    func firstServerHelloEph() throws -> Data {
        let keyStore = try DevKeyStore(dir: dir)   // 重新加载磁盘 = 模拟重启
        return try devEphemeralPubForOneHandshake(keyStore: keyStore, pairingCode: "c")
    }
    #expect(try firstServerHelloEph() != firstServerHelloEph())
}

@Test func singleHandshakeSameEphEstablishesSessionAndEchoes() throws {
    // 单次握手 hello/auth 用同一 eph → dev 侧建 SecureSession，且 iPad 侧同参能解 SecureReady（echo 不回归）。
    // 若 hello 与 auth 用了不同 eph，DH 对不上、verifyClientAuthAndFinish 必抛——本测试即是那道护栏。
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let keyStore = try DevKeyStore(dir: dir)
    let trust = try TrustStore(dir: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let ctx = DialoutContext(keyStore: keyStore, devDeviceId: "dev", sessionId: "room",
                             pairingCode: "c", expiresAt: Int64.max, trust: trust)

    let ipadIdentity = Curve25519.Signing.PrivateKey()
    let ipadEphemeral = Curve25519.KeyAgreement.PrivateKey()
    let hello = Handshake.makeClientHello(
        sessionId: "room", ipadDeviceId: "ipad-1",
        ipadIdentityPub: ipadIdentity.publicKey.rawRepresentation,
        ipadEphemeralPub: ipadEphemeral.publicKey.rawRepresentation,
        clientNonce: Data((0..<32).map { _ in UInt8.random(in: 0...255) }),
        pairingCode: "c")

    let shData = try ctx.handleClientHello(JSONEncoder().encode(hello))
    let serverHello = try JSONDecoder().decode(ServerHello.self, from: shData)
    let clientAuth = try Handshake.verifyServerHelloAndMakeClientAuth(
        clientHello: hello, serverHello: serverHello,
        devIdentityPub: keyStore.identityPublicKeyRaw, ipadIdentity: ipadIdentity)
    let ipadSession = try Handshake.finishClient(
        clientHello: hello, serverHello: serverHello,
        ipadEphemeral: ipadEphemeral, devIdentityPub: keyStore.identityPublicKeyRaw)

    let readyFrame = try ctx.handleClientAuth(JSONEncoder().encode(clientAuth))
    #expect(ctx.session != nil)   // dev 侧用同一 eph 建成会话

    // iPad 侧用同一握手派生的会话密钥解密 SecureReady（不为空 = echo 通）。
    let plaintext = try ipadSession.open(try SecureEnvelope(decoding: readyFrame))
    #expect(!plaintext.isEmpty)
    let ready = try JSONDecoder().decode(SecureReady.self, from: plaintext)
    #expect(ready.sessionId == "room")

    // 握手完成后 eph 已释放：磁盘上仍不存在交换私钥文件（仅 identity 持久化）。
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("exchange.key").path))
}
