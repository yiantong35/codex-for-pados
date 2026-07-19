import XCTest
import SwiftUI
@testable import CodexRemote

@MainActor
final class SessionsManagerTests: XCTestCase {
    private func mgr() -> SessionsManager {
        let name = "test.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        let store = MachineStore(defaults: d)
        return SessionsManager(machineStore: store, transportFactory: { _ in MockTransport() })
    }

    /// 根接线（Task 5 方案②）：RootView 只依赖 SessionsManager，不再读旧全局散 store。
    /// 空机器 → 渲染引导占位而不崩溃（旧 RootView 读未注入的 ConnectionStore/ProjectsStore/
    /// ApprovalStore 会在渲染时崩溃 → RED；改造后仅读 SessionsManager → GREEN）。
    func test_rootView_dependsOnlyOnSessionsManager_emptyMachines() {
        let store = MachineStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        XCTAssertTrue(store.machines.isEmpty)
        let sessions = SessionsManager(machineStore: store, transportFactory: { _ in MockTransport() })

        let view = RootView()
            .environment(sessions)
            .environment(LocaleManager())
            .environment(ThemeManager())
        let hc = UIHostingController(rootView: view)
        hc.view.frame = CGRect(x: 0, y: 0, width: 1194, height: 834)
        let window = UIWindow(frame: hc.view.frame)
        window.rootViewController = hc
        window.makeKeyAndVisible()
        hc.view.setNeedsLayout()
        hc.view.layoutIfNeeded()
        // 渲染未崩溃即证明 RootView 不再依赖旧全局 store；活跃会话为空（无机器）。
        XCTAssertNil(sessions.activeSession)
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
