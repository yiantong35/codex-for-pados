import XCTest
import Crypto
import RelayProtocol
@testable import CodexRemote

/// 测试用内存 StableSessionStore：按机器键存/取 stableSessionId（不落 UserDefaults）。
final class InMemoryStableSessionStore: StableSessionStoring, @unchecked Sendable {
    private var map: [String: String] = [:]
    private let lock = NSLock()
    func stableSessionId(machineKey: String) -> String? {
        lock.lock(); defer { lock.unlock() }; return map[machineKey]
    }
    func save(machineKey: String, stableSessionId: String) {
        lock.lock(); map[machineKey] = stableSessionId; lock.unlock()
    }
}

@MainActor
final class RelayTrustedHandshakeTests: XCTestCase {

    private func pairing(devPubB64: String, code: String) -> PairingPayload {
        PairingPayload(relayURL: "wss://relay.test", sessionId: "sess-trusted",
                       devIdentityPubB64: devPubB64, pairingCode: code, expiresAt: 9_999_999_999)
    }
    private func memKeyStore() -> KeyStoring {
        final class Mem: KeyStoring {
            private var d: Data?
            func saveKey(_ v: Data) { d = v }; func loadKey() -> Data? { d }; func deleteKey() { d = nil }
        }
        return Mem()
    }

    // MARK: 受信任握手（空 proof 免配对，仍双向验签 + TOFU）

    /// isTrustedReconnect=true → 发空 proof → dev 用 makeServerHelloTrusted 应答 → 握手成功建 SecureSession，
    /// TOFU 照常记信任，且业务帧往返正常（上层零改）。
    func testTrustedReconnectSucceedsWithEmptyProofAndRoundTrips() async throws {
        let dev = DevResponder(pairingCode: "unused-in-trusted")
        let ws = LoopbackRelayWSChannel { try dev.handle($0) }
        let e2e = RelayE2EKeyManager(store: memKeyStore())
        let tofu = InMemoryTOFUStore()

        let transport = RelayTransport(
            channelFactory: { ws }, pairing:pairing(devPubB64: dev.devIdentityPubB64, code: "unused-in-trusted"),
            ipadIdentity: e2e.identityKey(), ephemeralProvider: { Curve25519.KeyAgreement.PrivateKey() },
            tofu: tofu, tofuMachineKey: "machine-T",
            isTrustedReconnect: true, stableSessionStore: InMemoryStableSessionStore())

        var iter = transport.incoming().makeAsyncIterator()
        try await transport.awaitHandshake()

        // 受信任模式 TOFU 不省：仍记住了 dev 身份。
        XCTAssertEqual(tofu.rememberedIdentity(forMachineKey: "machine-T"),
                       Data(base64Encoded: dev.devIdentityPubB64))

        // 上层零改：SecureReady 已被 startReadLoop 前消费，业务帧往返不受干扰。
        try await transport.send("hi")
        let line = try await iter.next()
        XCTAssertEqual(line, "hi-echo")
    }

    /// 受信任模式仍验 dev 签名：dev 用与配对载荷不一致的身份签名 → iPad 验签失败 → 握手失败。
    func testTrustedModeStillVerifiesDevSignature() async throws {
        // dev 实际用一把随机身份签名，但配对载荷里放的是另一把（错误）身份公钥。
        let wrongDevPub = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        let dev = DevResponder(pairingCode: "x")
        let ws = LoopbackRelayWSChannel { frame in
            do { return try dev.handle(frame) } catch { throw TransportError.channelClosed(reason: "dev 拒绝") }
        }
        let e2e = RelayE2EKeyManager(store: memKeyStore())

        let transport = RelayTransport(
            channelFactory: { ws }, pairing:pairing(devPubB64: wrongDevPub, code: "x"),
            ipadIdentity: e2e.identityKey(), ephemeralProvider: { Curve25519.KeyAgreement.PrivateKey() },
            tofu: InMemoryTOFUStore(), tofuMachineKey: "m",
            isTrustedReconnect: true, stableSessionStore: InMemoryStableSessionStore())

        do {
            try await transport.awaitHandshake()
            XCTFail("受信任模式下 dev 身份不符仍应握手失败")
        } catch {
            // 预期：badServerSignature 冒泡为握手失败。
        }
    }

    // MARK: 消费 SecureReady 持久化 stableSessionId

    /// 受信任握手完成后，StableSessionStore 存下 dev 回发的 stableSessionId。
    func testTrustedHandshakeConsumesSecureReadyAndPersistsStableSessionId() async throws {
        let dev = DevResponder(pairingCode: "unused", stableSessionId: "stable-ABC")
        let ws = LoopbackRelayWSChannel { try dev.handle($0) }
        let e2e = RelayE2EKeyManager(store: memKeyStore())
        let store = InMemoryStableSessionStore()

        let transport = RelayTransport(
            channelFactory: { ws }, pairing:pairing(devPubB64: dev.devIdentityPubB64, code: "unused"),
            ipadIdentity: e2e.identityKey(), ephemeralProvider: { Curve25519.KeyAgreement.PrivateKey() },
            tofu: InMemoryTOFUStore(), tofuMachineKey: "machine-S",
            isTrustedReconnect: true, stableSessionStore: store)

        _ = transport.incoming()
        try await transport.awaitHandshake()

        XCTAssertEqual(store.stableSessionId(machineKey: "machine-S"), "stable-ABC")
    }

    /// 首配不回归：带 proof 的首配路径仍成功握手，且也消费 SecureReady 存 stableSessionId + 业务往返正常。
    func testFirstPairingStillConsumesSecureReadyAndRoundTrips() async throws {
        let code = "pair-first-1"
        let dev = DevResponder(pairingCode: code, stableSessionId: "stable-FIRST")
        let ws = LoopbackRelayWSChannel { try dev.handle($0) }
        let e2e = RelayE2EKeyManager(store: memKeyStore())
        let store = InMemoryStableSessionStore()

        let transport = RelayTransport(
            channelFactory: { ws }, pairing:pairing(devPubB64: dev.devIdentityPubB64, code: code),
            ipadIdentity: e2e.identityKey(), ephemeralProvider: { Curve25519.KeyAgreement.PrivateKey() },
            tofu: InMemoryTOFUStore(), tofuMachineKey: "machine-F",
            isTrustedReconnect: false, stableSessionStore: store)

        var iter = transport.incoming().makeAsyncIterator()
        try await transport.awaitHandshake()

        XCTAssertEqual(store.stableSessionId(machineKey: "machine-F"), "stable-FIRST")

        try await transport.send("ping")
        let line = try await iter.next()
        XCTAssertEqual(line, "ping-echo")
    }

    // MARK: 工厂判定（受信任复连 vs 首配）

    /// 已持久化 stableSessionId → 受信任复连：房间用 stableSessionId、isTrustedReconnect=true。
    func testRelayRoomDecisionTrustedWhenStored() {
        let store = InMemoryStableSessionStore()
        store.save(machineKey: "mk", stableSessionId: "room-stable")
        let d = relayRoomDecision(store: store, machineKey: "mk", payloadSessionId: "payload-sid")
        XCTAssertEqual(d.room, "room-stable")
        XCTAssertTrue(d.isTrustedReconnect)
    }

    /// 未持久化 → 首配：房间用 payload.sessionId、isTrustedReconnect=false。
    func testRelayRoomDecisionFirstPairingWhenAbsent() {
        let d = relayRoomDecision(store: InMemoryStableSessionStore(),
                                  machineKey: "mk", payloadSessionId: "payload-sid")
        XCTAssertEqual(d.room, "payload-sid")
        XCTAssertFalse(d.isTrustedReconnect)
    }

    // MARK: 生产 StableSessionStore（UserDefaults）往返

    func testUserDefaultsStableSessionStoreRoundTrip() {
        let suite = "test-stable-\(UUID().uuidString)"
        let store = UserDefaultsStableSessionStore(suiteName: suite)
        XCTAssertNil(store.stableSessionId(machineKey: "k"))
        store.save(machineKey: "k", stableSessionId: "v-123")
        XCTAssertEqual(store.stableSessionId(machineKey: "k"), "v-123")
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }
}
