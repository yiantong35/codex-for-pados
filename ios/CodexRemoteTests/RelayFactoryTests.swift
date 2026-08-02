import XCTest
@testable import CodexRemote

final class RelayFactoryTests: XCTestCase {

    /// relay MachineConfig → ConnectionConfig 带上稳定 TOFU 键（= MachineConfig id 字符串）。
    func testRelayMachineConfigCarriesTOFUKey() {
        let id = UUID()
        let m = MachineConfig(id: id, displayName: "relay-x",
                              relayURL: "wss://x", sessionId: "s", devIdentityPubB64: "QQ")
        let cfg = m.connectionConfig
        XCTAssertEqual(cfg.relayTOFUKey, id.uuidString, "relay 连接应带 MachineConfig id 作 TOFU 稳定键")
    }
}
