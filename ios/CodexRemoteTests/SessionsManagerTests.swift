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

    /// Important#1 回归：removeMachine 必须真的断连缓存 session（防连接泄漏）。
    /// 旧实现 `Task { await cache[id]?.disconnect() }` + 同步 `cache[id] = nil`：闭包体延迟
    /// 执行时 cache[id] 已为 nil → 断连从不发生。
    /// 这里用**空 host** 让 connect 同步落 .failed（该守卫路径不起后台 establish Task，故无 race），
    /// 把 phase 确定性推离 .disconnected；removeMachine 后若断连真的发生，disconnect() 会把
    /// phase 拉回 .disconnected。buggy 版本断连不发生 → phase 卡在 .failed → RED。
    func test_removeMachineDisconnectsCachedSession() async {
        let m = mgr()
        let mc = MachineConfig(host: "h", user: "u"); m.machineStore.add(mc)
        let s = m.session(for: mc.id)!
        // 空 host → connect 守卫同步落 .failed（无后台 Task，确定性推离 .disconnected）。
        s.connection.connect(config: ConnectionConfig(host: "", user: "u", controlSockPath: "/tmp/s.sock"))
        XCTAssertNotEqual(s.connection.phase, .disconnected, "前置：无效 connect 应同步落 .failed")

        m.removeMachine(id: mc.id)
        // removeMachine 内 `Task { await s.disconnect() }` 异步执行；轮询等它跑完。
        let disconnected = await waitUntil { s.connection.phase == .disconnected }
        XCTAssertTrue(disconnected,
                      "removeMachine 应断连缓存 session（disconnect() 真的被调用 → phase == .disconnected）")
    }

    /// Minor#4 兜底：非空机器时能取到 activeSession，且其 12 个功能 store 均已装配
    /// （间接保证 workspace(for:) 注入路径依赖的 store 都存在，防未来漏注入）。
    /// 12 个均为非可选 let，故以 ObjectIdentifier 收集去重断言全部存在且互为独立实例。
    func test_activeSessionHasAllTwelveStoresWired() {
        let m = mgr()
        let mc = MachineConfig(host: "h", user: "u"); m.machineStore.add(mc)
        m.setActive(mc.id)
        guard let s = m.activeSession else {
            return XCTFail("非空机器时 activeSession 不应为 nil")
        }
        let stores: [ObjectIdentifier] = [
            ObjectIdentifier(s.connection),
            ObjectIdentifier(s.projects),
            ObjectIdentifier(s.approvals),
            ObjectIdentifier(s.environment),
            ObjectIdentifier(s.mcp),
            ObjectIdentifier(s.skills),
            ObjectIdentifier(s.plugins),
            ObjectIdentifier(s.hooks),
            ObjectIdentifier(s.terminal),
            ObjectIdentifier(s.fileBrowser),
            ObjectIdentifier(s.sideChat),
            ObjectIdentifier(s.envInspector),
        ]
        XCTAssertEqual(Set(stores).count, 12, "12 个功能 store 应全部装配且互为独立实例")
    }

    /// 轮询等待条件成立（默认最多 ~2s），用于等 removeMachine 内的断连 Task 跑完。
    private func waitUntil(timeout: TimeInterval = 2.0,
                           _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)   // 5ms
        }
        return condition()
    }
}
