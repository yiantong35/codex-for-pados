import XCTest
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
