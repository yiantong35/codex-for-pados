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

/// Task 11：MachineConfig relay 连接类型 + 旧数据迁移。
final class MachineConfigRelayTests: XCTestCase {

    // SSH 便利构造器仍可用，且 shim 属性 + connection kind 能取回 host。
    func test_sshConfigStillWorks() {
        let m = MachineConfig(host: "devbox", user: "alice", sshPort: 2222,
                              sockPath: "/tmp/s.sock")
        XCTAssertEqual(m.host, "devbox")
        XCTAssertEqual(m.user, "alice")
        XCTAssertEqual(m.sshPort, 2222)
        XCTAssertEqual(m.sockPath, "/tmp/s.sock")
        guard case .ssh(let host, let user, let port, let sock) = m.connection else {
            return XCTFail("SSH 便利构造器应产出 .ssh kind")
        }
        XCTAssertEqual(host, "devbox")
        XCTAssertEqual(user, "alice")
        XCTAssertEqual(port, 2222)
        XCTAssertEqual(sock, "/tmp/s.sock")
    }

    // .relay(pairing:) 构造 → Codable round-trip → 相等（不丢 pairing）。
    func test_relayConfigRoundTripsCodable() throws {
        let pairing = "codexrelay://pair?relay=wss://r.example/ws&sid=S1&pk=PK&pc=PC&exp=9999999999"
        let m = MachineConfig(id: UUID(), displayName: "relay-box",
                              connection: .relay(pairing: pairing), lastActiveAt: nil)
        let data = try JSONEncoder().encode(m)
        let back = try JSONDecoder().decode(MachineConfig.self, from: data)
        XCTAssertEqual(back, m)
        guard case .relay(let p) = back.connection else {
            return XCTFail("round-trip 后应仍是 .relay kind")
        }
        XCTAssertEqual(p, pairing)
    }

    // 关键回归防线：旧格式扁平 JSON（有 host/user/sshPort/sockPath、无 connection 字段）
    // 必须迁移为 .ssh kind，数据不丢。
    func test_legacyFlatSSHJSONMigratesToSSHKind() throws {
        let id = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "displayName": "old-mac",
          "host": "10.0.0.5",
          "user": "bob",
          "sshPort": 2200,
          "sockPath": "/Users/bob/.codex/app-server-control/app-server-control.sock"
        }
        """
        let m = try JSONDecoder().decode(MachineConfig.self, from: Data(json.utf8))
        XCTAssertEqual(m.id, id)
        XCTAssertEqual(m.displayName, "old-mac")
        guard case .ssh(let host, let user, let port, let sock) = m.connection else {
            return XCTFail("旧扁平 JSON 应迁移为 .ssh kind")
        }
        XCTAssertEqual(host, "10.0.0.5")
        XCTAssertEqual(user, "bob")
        XCTAssertEqual(port, 2200)
        XCTAssertEqual(sock, "/Users/bob/.codex/app-server-control/app-server-control.sock")
    }
}
