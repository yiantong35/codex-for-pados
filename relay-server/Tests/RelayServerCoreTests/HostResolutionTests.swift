import XCTest
@testable import RelayServerCore

// F2（P1）：relay 默认绑定 loopback。
// 未设 RELAY_HOST → 127.0.0.1（公网不可直达，绕 TLS+Caddy 的裸连被杜绝）；
// 仅显式 RELAY_HOST 才绑定指定地址（生产经 Caddy 反代暴露 wss，逃生阀供本机排障）。
final class HostResolutionTests: XCTestCase {
    func test_default_binds_loopback() {
        XCTAssertEqual(RelayServerConfig.resolveHost(env: [:]), "127.0.0.1")
    }

    func test_explicit_RELAY_HOST_overrides() {
        XCTAssertEqual(RelayServerConfig.resolveHost(env: ["RELAY_HOST": "0.0.0.0"]), "0.0.0.0")
        XCTAssertEqual(RelayServerConfig.resolveHost(env: ["RELAY_HOST": "1.2.3.4"]), "1.2.3.4")
        XCTAssertEqual(RelayServerConfig.resolveHost(env: ["RELAY_HOST": "10.0.0.5"]), "10.0.0.5")
    }
}
