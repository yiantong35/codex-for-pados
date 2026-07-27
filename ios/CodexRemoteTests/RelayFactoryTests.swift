import XCTest
@testable import CodexRemote

final class RelayFactoryTests: XCTestCase {

    /// MachineConfig(.relay) → ConnectionConfig 带上稳定 TOFU 键（= MachineConfig id 字符串）。
    func testRelayMachineConfigCarriesTOFUKey() {
        let id = UUID()
        let m = MachineConfig(id: id, displayName: "relay-x",
                              connection: .relay(relayURL: "wss://x", sessionId: "s", devIdentityPubB64: "QQ"))
        let cfg = m.connectionConfig
        XCTAssertTrue(cfg.isRelay)
        XCTAssertEqual(cfg.relayTOFUKey, id.uuidString, "relay 连接应带 MachineConfig id 作 TOFU 稳定键")
    }

    /// SSH 连接不带 relayTOFUKey（零回归）。
    func testSSHMachineConfigHasNoTOFUKey() {
        let m = MachineConfig(host: "h", user: "u")
        XCTAssertNil(m.connectionConfig.relayTOFUKey)
    }
}
