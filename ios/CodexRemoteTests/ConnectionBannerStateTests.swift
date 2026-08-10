import XCTest
@testable import CodexRemote

@MainActor
final class ConnectionBannerStateTests: XCTestCase {
    private func store() -> ConnectionStore { ConnectionStore(transportFactory: { _ in MockTransport() }) }

    func test_ready_hidesBanner() async { let s = store(); s._test_setPhase(.ready); XCTAssertNil(s.bannerState) }
    func test_reconnecting_yellow() async { let s = store(); s._test_setPhase(.reconnecting); XCTAssertEqual(s.bannerState, .reconnecting) }
    func test_failed_red_preservesReason() async { let s = store(); s._test_setPhase(.failed("x")); XCTAssertEqual(s.bannerState, .failed("x")) }
    func test_trustRevoked_beatsFailed() async { let s = store(); s._test_setTrustRevoked(); XCTAssertEqual(s.bannerState, .trustRevoked) }
    func test_initializing_hidesBanner() async { let s = store(); s._test_setPhase(.initializing); XCTAssertNil(s.bannerState) }
    func test_connecting_hidesBanner() async { let s = store(); s._test_setPhase(.connecting); XCTAssertNil(s.bannerState) }
    func test_disconnected_hidesBanner() async { let s = store(); s._test_setPhase(.disconnected); XCTAssertNil(s.bannerState) }
}
