import XCTest
import Crypto
import RelayProtocol
@testable import CodexRemote

@MainActor
final class RelayHandshakeTests: XCTestCase {

    private func pairing(dev: DevResponder, code: String) -> PairingPayload {
        PairingPayload(relayURL: "wss://relay.test", sessionId: "sess-1",
                       devIdentityPubB64: dev.devIdentityPubB64, pairingCode: code,
                       expiresAt: 9_999_999_999)
    }

    /// 握手端到端：iPad 真跑 4 消息，建 SecureSession，awaitHandshake 返回 ready，再跑一个业务往返。
    func testHandshakeSucceedsAndRoundTrips() async throws {
        let code = "pair-code-123"
        let dev = DevResponder(pairingCode: code)
        let ws = LoopbackRelayWSChannel { try dev.handle($0) }
        let e2e = RelayE2EKeyManager(store: makeMemoryStore())
        let tofu = InMemoryTOFUStore()

        let transport = RelayTransport(
            channelFactory: { ws }, pairing: pairing(dev: dev, code: code),
            ipadIdentity: e2e.identityKey(), ephemeralProvider: { Curve25519.KeyAgreement.PrivateKey() },
            tofu: tofu, tofuMachineKey: "machine-A",
            isTrustedReconnect: false, stableSessionStore: InMemoryStableSessionStore())

        var iter = transport.incoming().makeAsyncIterator()
        try await transport.awaitHandshake()

        XCTAssertEqual(tofu.rememberedIdentity(forMachineKey: "machine-A"),
                       Data(base64Encoded: dev.devIdentityPubB64))

        try await transport.send("ping")
        let line = try await iter.next()
        XCTAssertEqual(line, "ping-echo")
    }

    /// 握手期 read loop 不得抢 ServerHello：即便 incoming() 先被消费，握手仍成功。
    func testReadLoopDoesNotStealHandshakeFrames() async throws {
        let code = "code-xyz"
        let dev = DevResponder(pairingCode: code)
        let ws = LoopbackRelayWSChannel { try dev.handle($0) }
        let e2e = RelayE2EKeyManager(store: makeMemoryStore())

        let transport = RelayTransport(
            channelFactory: { ws }, pairing: pairing(dev: dev, code: code),
            ipadIdentity: e2e.identityKey(), ephemeralProvider: { Curve25519.KeyAgreement.PrivateKey() },
            tofu: InMemoryTOFUStore(), tofuMachineKey: "m",
            isTrustedReconnect: false, stableSessionStore: InMemoryStableSessionStore())

        _ = transport.incoming()
        try await transport.awaitHandshake()
    }

    /// pairingCode 不符：dev 处理 ClientHello 即抛错→sendText 冒泡→performHandshake catch→awaitHandshake 抛错。
    func testWrongPairingCodeFailsHandshake() async throws {
        let dev = DevResponder(pairingCode: "right")
        let e2e = RelayE2EKeyManager(store: makeMemoryStore())
        let bad = PairingPayload(relayURL: "wss://relay.test", sessionId: "s",
                                 devIdentityPubB64: dev.devIdentityPubB64, pairingCode: "wrong",
                                 expiresAt: 9_999_999_999)
        // dev 拒绝握手时抛错，使回环通道确定性收敛（不挂起）。
        let driver = LoopbackRelayWSChannel { frame in
            do { return try dev.handle(frame) } catch { throw TransportError.channelClosed(reason: "dev 拒绝握手") }
        }
        let transport = RelayTransport(
            channelFactory: { driver }, pairing: bad, ipadIdentity: e2e.identityKey(),
            ephemeralProvider: { Curve25519.KeyAgreement.PrivateKey() }, tofu: InMemoryTOFUStore(), tofuMachineKey: "m",
            isTrustedReconnect: false, stableSessionStore: InMemoryStableSessionStore())

        do {
            try await transport.awaitHandshake()
            XCTFail("错误 pairingCode 应握手失败")
        } catch {
            // 期望明确抛错，不静默挂起。
        }
    }

    /// 握手失败后 incoming 流必须终止（抛错），不得让 JSONRPCClient pump 永久挂起。
    func testIncomingStreamFinishesOnHandshakeFailure() async throws {
        let dev = DevResponder(pairingCode: "right")
        let e2e = RelayE2EKeyManager(store: makeMemoryStore())
        let bad = PairingPayload(relayURL: "wss://relay.test", sessionId: "s",
                                 devIdentityPubB64: dev.devIdentityPubB64, pairingCode: "wrong",
                                 expiresAt: 9_999_999_999)
        let driver = LoopbackRelayWSChannel { frame in
            do { return try dev.handle(frame) } catch { throw TransportError.channelClosed(reason: "dev 拒绝握手") }
        }
        let transport = RelayTransport(
            channelFactory: { driver }, pairing: bad, ipadIdentity: e2e.identityKey(),
            ephemeralProvider: { Curve25519.KeyAgreement.PrivateKey() }, tofu: InMemoryTOFUStore(), tofuMachineKey: "m",
            isTrustedReconnect: false, stableSessionStore: InMemoryStableSessionStore())

        var iter = transport.incoming().makeAsyncIterator()
        do { try await transport.awaitHandshake(); XCTFail("应握手失败") } catch { /* 预期 */ }

        // 关键断言：incoming 流已终止（抛错），不挂起。
        do {
            _ = try await iter.next()
            XCTFail("握手失败后 incoming 流应抛错终止，而非挂起或正常结束")
        } catch {
            // 预期：channelClosed
        }
    }

    // MARK: helpers
    private func makeMemoryStore() -> KeyStoring {
        final class Mem: KeyStoring {
            private var d: Data?
            func saveKey(_ v: Data) { d = v }
            func loadKey() -> Data? { d }
            func deleteKey() { d = nil }
        }
        return Mem()
    }
}
