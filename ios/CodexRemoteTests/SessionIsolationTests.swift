import XCTest
@testable import CodexRemote

@MainActor
final class SessionIsolationTests: XCTestCase {
    func test_twoSessionsHaveDistinctStores() {
        let m1 = MachineConfig(host: "h1", user: "u1")
        let m2 = MachineConfig(host: "h2", user: "u2")
        let s1 = Session(machine: m1, transportFactory: { _ in MockTransport() })
        let s2 = Session(machine: m2, transportFactory: { _ in MockTransport() })
        XCTAssertFalse(s1.projects === s2.projects)
        XCTAssertFalse(s1.environment === s2.environment)
        XCTAssertFalse(s1.connection === s2.connection)
    }

    func test_sessionExposesMachineIdentity() {
        let m = MachineConfig(host: "h", user: "u")
        let s = Session(machine: m, transportFactory: { _ in MockTransport() })
        XCTAssertEqual(s.id, m.id)
        XCTAssertEqual(s.machine.host, "h")
    }
}
