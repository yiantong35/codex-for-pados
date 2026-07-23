import XCTest
import Crypto
import RelayProtocol
@testable import CodexRemote

@MainActor
final class RelayIntegrationTests: XCTestCase {

    private func pairing(devPubB64: String, sid: String, code: String) -> PairingPayload {
        PairingPayload(relayURL: "wss://relay.test", sessionId: sid,
                       devIdentityPubB64: devPubB64, pairingCode: code, expiresAt: 9_999_999_999)
    }
    private func memStore() -> KeyStoring {
        final class Mem: KeyStoring {
            private var d: Data?
            func saveKey(_ v: Data) { d = v }; func loadKey() -> Data? { d }; func deleteKey() { d = nil }
        }
        return Mem()
    }

    /// 完整握手 + 多帧业务往返（模拟 dialout 端到端一个往返，全内存）。
    func testFullHandshakeAndMultipleRoundTrips() async throws {
        let code = "code-int"
        let dev = DevResponder(pairingCode: code)
        let ws = LoopbackRelayWSChannel { try dev.handle($0) }
        let e2e = RelayE2EKeyManager(store: memStore())

        let t = RelayTransport(
            ws: ws, pairing: pairing(devPubB64: dev.devIdentityPubB64, sid: "s", code: code),
            ipadIdentity: e2e.identityKey(), ipadEphemeral: e2e.newEphemeralKey(),
            tofu: InMemoryTOFUStore(), tofuMachineKey: "m")

        var iter = t.incoming().makeAsyncIterator()
        try await t.awaitHandshake()

        for msg in ["a", "bb", "ccc"] {
            try await t.send(msg)
            let echoed = try await iter.next()
            XCTAssertEqual(echoed, "\(msg)-echo")
        }
    }

    /// 跨连接 TOFU：连接①首信记下 dev①身份；连接②同机器键但 dev 换了身份 → 拒连。
    func testTOFURejectsChangedDevIdentityAcrossConnections() async throws {
        let sharedTOFU = InMemoryTOFUStore()
        let machineKey = "same-machine"

        let dev1 = DevResponder(pairingCode: "c1")
        let ws1 = LoopbackRelayWSChannel { try dev1.handle($0) }
        let e2e1 = RelayE2EKeyManager(store: memStore())
        let t1 = RelayTransport(
            ws: ws1, pairing: pairing(devPubB64: dev1.devIdentityPubB64, sid: "s1", code: "c1"),
            ipadIdentity: e2e1.identityKey(), ipadEphemeral: e2e1.newEphemeralKey(),
            tofu: sharedTOFU, tofuMachineKey: machineKey)
        _ = t1.incoming()
        try await t1.awaitHandshake()   // 成功，记下 dev1

        let dev2 = DevResponder(pairingCode: "c2")   // 新随机身份
        let ws2 = LoopbackRelayWSChannel { try dev2.handle($0) }
        let e2e2 = RelayE2EKeyManager(store: memStore())
        let t2 = RelayTransport(
            ws: ws2, pairing: pairing(devPubB64: dev2.devIdentityPubB64, sid: "s2", code: "c2"),
            ipadIdentity: e2e2.identityKey(), ipadEphemeral: e2e2.newEphemeralKey(),
            tofu: sharedTOFU, tofuMachineKey: machineKey)
        _ = t2.incoming()
        do {
            try await t2.awaitHandshake()
            XCTFail("开发机身份变更应被 TOFU 拒连")
        } catch {
            // 期望 TOFUError.identityChanged 冒泡为握手失败。
        }
    }
}
