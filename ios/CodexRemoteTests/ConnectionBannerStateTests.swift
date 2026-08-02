import XCTest
@testable import CodexRemote

/// 连接异常横幅态映射逻辑（缺口 3、4）。
/// 校验 `ConnectionStore.bannerState` 三态映射：reconnecting/failed/trustRevoked，
/// 且信任撤销（needsRePairing）优先于普通 failed；其余 phase 隐藏（nil）。
@MainActor
final class ConnectionBannerStateTests: XCTestCase {
    private func store() -> ConnectionStore { ConnectionStore(transportFactory: { _ in MockTransport() }) }

    func test_ready_hidesBanner() async {
        let s = store(); s._test_setPhase(.ready)
        XCTAssertNil(s.bannerState)
    }
    func test_reconnecting_yellow() async {
        let s = store(); s._test_setPhase(.reconnecting)
        XCTAssertEqual(s.bannerState, .reconnecting)
    }
    func test_failed_red() async {
        let s = store(); s._test_setPhase(.failed("x"))
        XCTAssertEqual(s.bannerState, .failed)
    }
    func test_trustRevoked_beatsFailed() async {
        let s = store(); s._test_setTrustRevoked()   // 置 needsRePairing=true + phase=.failed
        XCTAssertEqual(s.bannerState, .trustRevoked)   // 信任撤销优先于普通 failed
    }
    func test_initializing_hidesBanner() async {
        let s = store(); s._test_setPhase(.initializing)
        XCTAssertNil(s.bannerState)
    }
    func test_connecting_hidesBanner() async {
        let s = store(); s._test_setPhase(.connecting)
        XCTAssertNil(s.bannerState)
    }
    func test_disconnected_hidesBanner() async {
        let s = store(); s._test_setPhase(.disconnected)
        XCTAssertNil(s.bannerState)
    }
}
