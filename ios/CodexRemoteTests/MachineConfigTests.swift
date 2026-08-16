import XCTest
import Crypto
import RelayProtocol
@testable import CodexRemote

final class MachineConfigTests: XCTestCase {
    func test_encodeDecodeRoundtrip() throws {
        let m = MachineConfig(id: UUID(), displayName: "macmini",
                              relayURL: "wss://relay.example/ws", sessionId: "sess-1",
                              devIdentityPubB64: "PK", lastActiveAt: nil)
        let data = try JSONEncoder().encode(m)
        let back = try JSONDecoder().decode(MachineConfig.self, from: data)
        XCTAssertEqual(back, m)
    }

    func test_decodesPreviousNestedRelayAndNormalizesEncoding() throws {
        let id = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "displayName": "legacy-relay",
          "connection": {
            "kind": "relay",
            "relayURL": "wss://legacy.example/ws",
            "sessionId": "legacy-session",
            "devIdentityPubB64": "LEGACY-PK"
          }
        }
        """

        let decoded = try JSONDecoder().decode(MachineConfig.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.id, id)
        XCTAssertEqual(decoded.displayName, "legacy-relay")
        XCTAssertEqual(decoded.relayURL, "wss://legacy.example/ws")
        XCTAssertEqual(decoded.sessionId, "legacy-session")
        XCTAssertEqual(decoded.devIdentityPubB64, "LEGACY-PK")

        let normalized = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any]
        )
        XCTAssertEqual(normalized["relayURL"] as? String, "wss://legacy.example/ws")
        XCTAssertNil(normalized["connection"])
        XCTAssertNil(normalized["pairing"])
    }

    func test_decodesLegacyPairingWithoutPersistingPairingCode() throws {
        let devIdentityPubB64 = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(repeating: 0x42, count: 32)
        ).publicKey.rawRepresentation.base64EncodedString()
        let payload = PairingPayload(relayURL: "wss://pairing.example/ws",
                                     sessionId: "pairing-session",
                                     devIdentityPubB64: devIdentityPubB64,
                                     pairingCode: "SECRET-PAIRING-CODE",
                                     expiresAt: 1_900_000_000)
        let object: [String: Any] = [
            "id": UUID().uuidString,
            "displayName": "legacy-pairing",
            "connection": [
                "kind": "relay",
                "pairing": payload.toURLString(),
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(MachineConfig.self, from: data)
        XCTAssertEqual(decoded.relayURL, payload.relayURL)
        XCTAssertEqual(decoded.sessionId, payload.sessionId)
        XCTAssertEqual(decoded.devIdentityPubB64, payload.devIdentityPubB64)

        let normalizedData = try JSONEncoder().encode(decoded)
        let normalizedText = try XCTUnwrap(String(data: normalizedData, encoding: .utf8))
        let normalized = try XCTUnwrap(
            JSONSerialization.jsonObject(with: normalizedData) as? [String: Any]
        )
        XCTAssertFalse(normalizedText.contains(payload.pairingCode))
        XCTAssertNil(normalized["pairing"])
        XCTAssertNil(normalized["connection"])
    }

    func test_rejectsLegacyPairingWithInvalidDevIdentityPublicKey() throws {
        let payload = PairingPayload(relayURL: "wss://pairing.example/ws",
                                     sessionId: "pairing-session",
                                     devIdentityPubB64: "PAIRING-PK",
                                     pairingCode: "SECRET-PAIRING-CODE",
                                     expiresAt: 1_900_000_000)
        let object: [String: Any] = [
            "id": UUID().uuidString,
            "displayName": "invalid-legacy-pairing",
            "connection": [
                "kind": "relay",
                "pairing": payload.toURLString(),
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try JSONDecoder().decode(MachineConfig.self, from: data)) { error in
            XCTAssertEqual(error as? PairingError, .badFormat)
        }
    }
}

/// MachineConfig relay 连接类型（relay-only）。
final class MachineConfigRelayTests: XCTestCase {

    // relay 构造 → Codable round-trip → 相等（结构化非密字段，不含 pc）。
    func test_relayConfigRoundTripsCodable() throws {
        let m = MachineConfig(id: UUID(), displayName: "relay-box",
                              relayURL: "wss://r.example/ws", sessionId: "S1",
                              devIdentityPubB64: "PK", lastActiveAt: nil)
        let data = try JSONEncoder().encode(m)
        let back = try JSONDecoder().decode(MachineConfig.self, from: data)
        XCTAssertEqual(back, m)
        XCTAssertEqual(back.relayURL, "wss://r.example/ws")
        XCTAssertEqual(back.sessionId, "S1")
        XCTAssertEqual(back.devIdentityPubB64, "PK")
    }
}
