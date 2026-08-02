import XCTest
@testable import CodexRemote

@MainActor
final class SessionIsolationTests: XCTestCase {
    func test_twoSessionsHaveDistinctStores() {
        let m1 = MachineConfig(displayName: "h1", relayURL: "wss://h1", sessionId: "s1", devIdentityPubB64: "p1")
        let m2 = MachineConfig(displayName: "h2", relayURL: "wss://h2", sessionId: "s2", devIdentityPubB64: "p2")
        let s1 = Session(machine: m1, transportFactory: { _ in MockTransport() })
        let s2 = Session(machine: m2, transportFactory: { _ in MockTransport() })
        XCTAssertFalse(s1.projects === s2.projects)
        XCTAssertFalse(s1.environment === s2.environment)
        XCTAssertFalse(s1.connection === s2.connection)
    }

    func test_sessionExposesMachineIdentity() {
        let m = MachineConfig(displayName: "h", relayURL: "wss://h", sessionId: "s", devIdentityPubB64: "p")
        let s = Session(machine: m, transportFactory: { _ in MockTransport() })
        XCTAssertEqual(s.id, m.id)
        XCTAssertEqual(s.machine.displayName, "h")
    }
}
