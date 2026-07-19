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

    /// Task 9 gating 回归（行为）：首次/未连接态（machines 空）根据 gating 不应有活跃会话，
    /// 即不进入 workspace（RootSplitView topBar 的齿轮所在），而落到 OnboardingView。
    /// 与 `test_rootView_dependsOnlyOnSessionsManager_emptyMachines` 呼应；这里聚焦「无 workspace 入口」。
    func test_emptyMachines_gatingKeepsUserOutOfWorkspace() {
        let store = MachineStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        XCTAssertTrue(store.machines.isEmpty)
        let sessions = SessionsManager(machineStore: store, transportFactory: { _ in MockTransport() })
        // gating 契约：空机器 → activeSession 为 nil → RootView 不渲染含齿轮的 workspace 分支。
        XCTAssertNil(sessions.activeSession,
                     "空机器时不得有活跃会话（否则会进入含设置齿轮的 workspace）")
    }

    /// Task 9 gating 回归（结构）：设置齿轮入口只允许存在于主界面 topBar（RootSplitView），
    /// 首次/未连接态的两个视图（OnboardingView 引导页、MachineFormView 加机器表单）不得含齿轮。
    ///
    /// 说明：SwiftUI 的无障碍/视图树在 XCTest 无障碍技术未激活的无头环境下不会同步落地
    /// （实测 UIHostingController 采集 a11y label 恒空），故不用运行时快照，改用**源码级结构断言**：
    /// 齿轮以 `Image(systemName: "gearshape")` 呈现，`gearshape` 字面量是稳定标记。
    /// - 正向对照：RootSplitView 源码**必含** `gearshape`（证明扫描器确实能识别齿轮标记，
    ///   否则「引导页无齿轮」可能只是扫描器失效的假阳性）；
    /// - 负向断言：OnboardingView / MachineFormView 源码**不得含** `gearshape`。
    /// RED 证据：给 OnboardingView 源码加回 `Image(systemName: "gearshape")` → 负向断言失败。
    func test_settingsGear_onlyInMainTopBar_notInOnboardingOrForm() throws {
        let viewsDir = Self.viewsDirectory()
        let gearToken = "gearshape"

        // 正向对照：主界面 topBar 视图必含齿轮标记（扫描器有效性自证）。
        let rootSplit = try String(contentsOf: viewsDir.appendingPathComponent("RootSplitView.swift"), encoding: .utf8)
        XCTAssertTrue(rootSplit.contains(gearToken),
                      "RootSplitView 应含设置齿轮标记 \(gearToken)（正向对照：证明扫描器能识别齿轮）")

        // 负向断言：首次/未连接态视图不得含齿轮入口。
        for name in ["OnboardingView.swift", "MachineFormView.swift"] {
            let src = try String(contentsOf: viewsDir.appendingPathComponent(name), encoding: .utf8)
            XCTAssertFalse(src.contains(gearToken),
                           "\(name) 不得含设置齿轮入口（首次/未连接态无设置入口 gating）")
        }
    }

    /// 由本测试文件路径（#filePath）推导源码 Views 目录，避免硬编码绝对路径。
    /// 结构：<repo>/ios/CodexRemoteTests/SessionsManagerTests.swift →
    ///       <repo>/ios/CodexRemote/Views/
    private static func viewsDirectory() -> URL {
        URL(fileURLWithPath: #filePath)            // .../ios/CodexRemoteTests/SessionsManagerTests.swift
            .deletingLastPathComponent()           // .../ios/CodexRemoteTests
            .deletingLastPathComponent()           // .../ios
            .appendingPathComponent("CodexRemote/Views")
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
