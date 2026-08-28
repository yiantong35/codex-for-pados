import Testing
import Foundation
import Crypto
import RelayProtocol
@testable import RelayDialoutCore

/// 缺陷 #1（dev 侧）A3 红测：dev 拨出常驻连接上，握手已起（hellos != nil）后到达的新 `ClientHello`
/// 必须被 dispatch 判定为「(重)握手起始」并重建握手，而非当迟到 `ClientAuth` 丢弃。
///
/// 判定单元 = `DialoutContext.classifyHandshakeFrame`（纯函数，按帧类型分类）。旧 dispatch
/// 在 `hellos != nil` 时一律走 `handleClientAuth`，对新 `ClientHello` 解失败即 return 丢弃——
/// iPad 因此永远收不到新 ServerHello、连接内重握手失败。
struct DialoutContextRehandshakeDispatchTests {

    /// 造一台受信任 iPad + DialoutContext，并返回构造 ClientHello 的闭包（受信任复连免 proof）。
    private struct Harness {
        let devKeyStore: DevKeyStore
        let trust: TrustStore
        let ipadIdentity: Curve25519.Signing.PrivateKey
        let context: DialoutContext

        init() throws {
            let devDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let trustDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            self.devKeyStore = try DevKeyStore(dir: devDir)
            self.trust = try TrustStore(dir: trustDir)
            self.ipadIdentity = Curve25519.Signing.PrivateKey()
            try trust.trust(ipadPubB64: ipadIdentity.publicKey.rawRepresentation.base64EncodedString(),
                            stableSessionId: "stable-fixed", label: nil)
            self.context = DialoutContext(keyStore: devKeyStore, devDeviceId: "dev-1",
                                          sessionId: "stable-fixed", pairingCode: "PAIR-OK",
                                          expiresAt: Int64(Date().timeIntervalSince1970) + 600, trust: trust)
        }

        func hello(ephemeral: Curve25519.KeyAgreement.PrivateKey) -> ClientHello {
            var h = Handshake.makeClientHello(
                sessionId: "room-1", ipadDeviceId: "ipad-1",
                ipadIdentityPub: ipadIdentity.publicKey.rawRepresentation,
                ipadEphemeralPub: ephemeral.publicKey.rawRepresentation,
                clientNonce: Data((0..<32).map { _ in UInt8.random(in: 0...255) }),
                pairingCode: "unused")
            h.pairingCodeProof = Data()   // 受信任复连免 proof
            return h
        }

        /// 走完一轮真实握手，返回 iPad 侧对本轮的 ClientAuth（用于验证 auth 帧分类）。
        func driveOnce(ephemeral: Curve25519.KeyAgreement.PrivateKey) throws -> ClientAuth {
            let h = hello(ephemeral: ephemeral)
            let shData = try context.handleClientHello(JSONEncoder().encode(h))
            let sh = try JSONDecoder().decode(ServerHello.self, from: shData)
            let auth = try Handshake.verifyServerHelloAndMakeClientAuth(
                clientHello: h, serverHello: sh,
                devIdentityPub: devKeyStore.identityPublicKeyRaw, ipadIdentity: ipadIdentity)
            _ = try context.handleClientAuth(JSONEncoder().encode(auth))
            return auth
        }
    }

    /// ClientHello 帧 → `.clientHello`（旧 dispatch 在 hellos!=nil 时会误当 ClientAuth 丢弃，此为缺陷根因）。
    @Test func clientHelloFrameRoutesToClientHello() throws {
        let h = try Harness()
        let data = try JSONEncoder().encode(h.hello(ephemeral: Curve25519.KeyAgreement.PrivateKey()))
        #expect(DialoutContext.classifyHandshakeFrame(data) == .clientHello)
    }

    /// ClientAuth 帧 → `.clientAuth`（不得误判为 ClientHello，保握手收尾路径不回归）。
    @Test func clientAuthFrameRoutesToClientAuth() throws {
        let h = try Harness()
        let auth = try h.driveOnce(ephemeral: Curve25519.KeyAgreement.PrivateKey())
        let data = try JSONEncoder().encode(auth)
        #expect(DialoutContext.classifyHandshakeFrame(data) == .clientAuth)
    }

    /// decode 不相交见证：ClientHello 帧按 ClientAuth 解必失败——这正是旧 dispatch 把新 Hello
    /// 当 ClientAuth（try handleClientAuth 抛错）后 return 丢弃的根因。
    @Test func clientHelloIsNotDecodableAsClientAuth() throws {
        let h = try Harness()
        let data = try JSONEncoder().encode(h.hello(ephemeral: Curve25519.KeyAgreement.PrivateKey()))
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(ClientAuth.self, from: data)
        }
    }

    /// 端到端：同一受信任 DialoutContext 首次握手完成（hellos/session 就绪）后再来一个新 ClientHello，
    /// 仍须分类为 `.clientHello` 并经 handleClientHello 产出**新一轮** ServerHello（连接内重握手），
    /// 不被当 ClientAuth 丢弃。
    @Test func rehandshakeAfterFirstHandshakeProducesFreshServerHello() throws {
        let h = try Harness()

        // 首次握手：建 session。
        _ = try h.driveOnce(ephemeral: Curve25519.KeyAgreement.PrivateKey())
        #expect(h.context.hellos != nil)
        #expect(h.context.session != nil)
        let sh1Ephemeral = h.context.hellos?.1.devEphemeralPub

        // 连接内重握手：新 ClientHello（新 ephemeral）到达——关键断言：hellos!=nil 时仍判 .clientHello。
        let h2Data = try JSONEncoder().encode(h.hello(ephemeral: Curve25519.KeyAgreement.PrivateKey()))
        #expect(DialoutContext.classifyHandshakeFrame(h2Data) == .clientHello)
        let sh2Data = try h.context.handleClientHello(h2Data)
        let sh2 = try JSONDecoder().decode(ServerHello.self, from: sh2Data)
        #expect(sh2.devEphemeralPub != sh1Ephemeral)   // 新一轮握手新 dev ephemeral（前向保密）
    }
}
