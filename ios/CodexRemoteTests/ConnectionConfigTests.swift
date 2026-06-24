import XCTest
@testable import CodexRemote

final class ConnectionConfigTests: XCTestCase {
    /// wsURL 不应携带 token query（token 改走 Authorization: Bearer header，避免日志/历史泄漏）。
    func testWSURLHasNoTokenQuery() {
        let cfg = ConnectionConfig(host: "h", port: 8900, token: "secret")
        let s = cfg.wsURL.absoluteString
        XCTAssertFalse(s.contains("token="), "wsURL 不应含 token query；实际: \(s)")
        XCTAssertEqual(cfg.wsURL.scheme, "ws")
        XCTAssertEqual(cfg.wsURL.host, "h")
        XCTAssertEqual(cfg.wsURL.port, 8900)
    }
}
