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

    @Test func legacyRelayPairingStringMigratesStrippingPairingCode() throws {
        // 构造旧格式：connection.kind == relay, pairing == 含 pc 的 URI。
        let legacyURI = "codexrelay://pair?relay=wss://r.example/ws&sid=sidOld&pk=PUBOLD&pc=SECRET123&exp=9999999999"
        let legacyJSON = """
        {"id":"\(UUID().uuidString)","displayName":"old","connection":{"kind":"relay","pairing":"\(legacyURI)"}}
        """
        let cfg = try JSONDecoder().decode(MachineConfig.self, from: Data(legacyJSON.utf8))
        guard case .relay(let url, let sid, let pub) = cfg.connection else { return #expect(Bool(false)) }
        #expect(url == "wss://r.example/ws" && sid == "sidOld" && pub == "PUBOLD")
        // 重新编码后绝不含 pc。
        let reEncoded = String(decoding: try JSONEncoder().encode(cfg), as: UTF8.self)
        #expect(!reEncoded.contains("SECRET123") && !reEncoded.contains("pc="))
    }
}
