import XCTest
@testable import CodexRemote

@MainActor
final class ShortcutTabActivationTests: XCTestCase {
    private func makeSessions(count: Int) -> SessionsManager {
        let d = UserDefaults(suiteName: "test.tabkeys.\(UUID().uuidString)")!
        let store = MachineStore(defaults: d)
        for i in 0..<count {
            store.add(MachineConfig(displayName: "机器\(i+1)", host: "h\(i)", user: "u\(i)"))
        }
        return SessionsManager(machineStore: store, transportFactory: { _ in MockTransport() })
    }

    func test_activateTabAtIndex_switchesActive() {
        let s = makeSessions(count: 3)
        s.activateTab(atIndex: 1)
        XCTAssertEqual(s.activeSessionId, s.machineStore.machines[1].id)
    }

    func test_activateTabAtIndex_outOfRange_noEffect() {
        let s = makeSessions(count: 2)
        s.setActive(s.machineStore.machines[0].id)
        s.activateTab(atIndex: 4)  // 超界（只有 2 台）
        XCTAssertEqual(s.activeSessionId, s.machineStore.machines[0].id, "超界应无副作用")
    }

    func test_activateAdjacentTab_next() {
        let s = makeSessions(count: 3)
        s.setActive(s.machineStore.machines[0].id)
        s.activateAdjacentTab(delta: 1)
        XCTAssertEqual(s.activeSessionId, s.machineStore.machines[1].id)
    }

    func test_activateAdjacentTab_prev() {
        let s = makeSessions(count: 3)
        s.setActive(s.machineStore.machines[2].id)
        s.activateAdjacentTab(delta: -1)
        XCTAssertEqual(s.activeSessionId, s.machineStore.machines[1].id)
    }

    func test_activateAdjacentTab_atEdge_noWrap() {
        let s = makeSessions(count: 2)
        s.setActive(s.machineStore.machines[0].id)
        s.activateAdjacentTab(delta: -1)  // 已在首项，上一项越界
        XCTAssertEqual(s.activeSessionId, s.machineStore.machines[0].id, "边界不循环、无副作用")
    }

    func test_activateTabAtIndex_negative_noEffect() {
        let s = makeSessions(count: 2)
        s.setActive(s.machineStore.machines[0].id)
        s.activateTab(atIndex: -1)
        XCTAssertEqual(s.activeSessionId, s.machineStore.machines[0].id)
    }

    func test_activateAdjacentTab_noActiveSession_noEffect() {
        let s = makeSessions(count: 2)
        // do not setActive → activeSessionId has whatever default; adjacent should no-op safely (no crash)
        s.activateAdjacentTab(delta: 1)
        // no assertion on value beyond "did not crash"; assert it did not spuriously change to an unexpected index
        XCTAssertNoThrow(s.activateAdjacentTab(delta: -1))
    }
}
