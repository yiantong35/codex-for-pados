import XCTest
@testable import CodexRemote

@MainActor
final class SessionsManagerTests: XCTestCase {
    private func mgr() -> SessionsManager {
        let name = "test.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        let store = MachineStore(defaults: d)
        return SessionsManager(machineStore: store, transportFactory: { _ in MockTransport() })
    }

    func test_sessionCachedAndReusedPerMachine() {
        let m = mgr()
        let mc = MachineConfig(host: "h", user: "u")
        m.machineStore.add(mc)
        let s1 = m.session(for: mc.id)
        let s2 = m.session(for: mc.id)
        XCTAssertTrue(s1 === s2)   // 缓存保活：同机器同一 Session 实例
    }

    func test_activeSessionFollowsActiveMachine() {
        let m = mgr()
        let a = MachineConfig(host: "a", user: "u"); m.machineStore.add(a)
        let b = MachineConfig(host: "b", user: "u"); m.machineStore.add(b)
        m.setActive(a.id)
        XCTAssertEqual(m.activeSession?.id, a.id)
        m.setActive(b.id)
        XCTAssertEqual(m.activeSession?.id, b.id)
    }

    func test_removeDropsSessionAndMachine() {
        let m = mgr()
        let mc = MachineConfig(host: "h", user: "u"); m.machineStore.add(mc)
        _ = m.session(for: mc.id)
        m.removeMachine(id: mc.id)
        XCTAssertTrue(m.machineStore.machines.isEmpty)
        XCTAssertNil(m.activeSession)
    }
}
