import Testing
import Foundation
@testable import CodexRemote

/// Task 5.2：`ConnectionKind.relay` 结构化非密字段（去掉 pairing 载荷字符串）——
/// 持久化 JSON 里不应再出现配对码（pc=/pairingCode），配对码单独走内存 PendingPairingStore。
struct MachineConfigRelayMigrationTests {

    @Test func relayConfigEncodesOnlyNonSecretFields() throws {
        let cfg = MachineConfig(displayName: "mac",
            connection: .relay(relayURL: "wss://r.example/ws", sessionId: "sid1", devIdentityPubB64: "PUB"))
        let data = try JSONEncoder().encode(cfg)
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("pc="))          // 无配对码
        #expect(!json.lowercased().contains("paircode"))
        #expect(json.contains("relayURL") || json.contains("relay"))
        // 往返可解
        let back = try JSONDecoder().decode(MachineConfig.self, from: data)
        if case .relay(let url, let sid, let pub) = back.connection {
            #expect(url == "wss://r.example/ws" && sid == "sid1" && pub == "PUB")
        } else { #expect(Bool(false)) }
    }
}
