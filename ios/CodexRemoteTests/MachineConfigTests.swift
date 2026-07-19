import XCTest
@testable import CodexRemote

final class MachineConfigTests: XCTestCase {
    func test_encodeDecodeRoundtrip() throws {
        let m = MachineConfig(id: UUID(), displayName: "macmini", host: "127.0.0.1",
                              user: "tangyujie", sshPort: 22,
                              sockPath: "/Users/tangyujie/.codex/app-server-control/app-server-control.sock",
                              lastActiveAt: nil)
        let data = try JSONEncoder().encode(m)
        let back = try JSONDecoder().decode(MachineConfig.self, from: data)
        XCTAssertEqual(back, m)
    }

    func test_sockPathDerivation() {
        XCTAssertEqual(MachineConfig.sockPath(forUser: "alice"),
                       "/Users/alice/.codex/app-server-control/app-server-control.sock")
    }

    func test_defaultDisplayNameFallsBackToHost() {
        let m = MachineConfig(host: "devbox", user: "u")
        XCTAssertEqual(m.displayName, "devbox")
    }
}
