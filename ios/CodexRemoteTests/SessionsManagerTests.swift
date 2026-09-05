import XCTest
import SwiftUI
@testable import CodexRemote

@MainActor
final class SessionsManagerTests: XCTestCase {
    func testExplicitDisconnectSurvivesTabAndForegroundAutoConnectPaths() async {
        let mock = MockTransport()
        await mock.setBlockHandshake(true)
        let store = MachineStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        let manager = SessionsManager(machineStore: store, transportFactory: { _ in mock })
        let first = relayMC("intent-a")
        let second = relayMC("intent-b")
        store.add(first); store.add(second)
        manager.setActive(first.id)
        let session = manager.session(for: first.id)!
        _ = await waitUntil { session.connection.inFlightTransportForTesting != nil }

        manager.disconnect(id: first.id)
        _ = await waitUntil { session.connection.phase == .disconnected }
        XCTAssertEqual(session.connectionIntent, .disconnectedByUser)
        manager.setActive(second.id)
        manager.setActive(first.id)
        manager.setAppForegroundAll(true)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(session.connection.phase, .disconnected)
    }

    func testExplicitDisconnectIntentPersistsAndExplicitConnectClearsIt() async {
        let suite = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = MachineStore(defaults: defaults)
        let manager = SessionsManager(machineStore: store, transportFactory: { _ in MockTransport() })
        let machine = relayMC("persist-intent")
        store.add(machine)
        _ = manager.session(for: machine.id)
        manager.disconnect(id: machine.id)
        XCTAssertEqual(store.machines.first?.connectionIntent, .disconnectedByUser)

        let reloaded = MachineStore(defaults: defaults)
        XCTAssertEqual(reloaded.machines.first?.connectionIntent, .disconnectedByUser)
        let reloadedManager = SessionsManager(machineStore: reloaded, transportFactory: { _ in MockTransport() })
        reloadedManager.bootstrapAutoConnect()
        XCTAssertEqual(reloadedManager.activeSession?.connection.phase, .disconnected)

        reloadedManager.connectMachine(id: machine.id)
        XCTAssertEqual(reloaded.machines.first?.connectionIntent, .automatic)
    }
    private func mgr() -> SessionsManager {
        let name = "test.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        let store = MachineStore(defaults: d)
        return SessionsManager(machineStore: store, transportFactory: { _ in MockTransport() })
    }

    /// relay-only 机器构造 helper（displayName 兼作用例内标识）。
    private func relayMC(_ name: String) -> MachineConfig {
        MachineConfig(displayName: name, relayURL: "wss://\(name)",
                      sessionId: "s-\(name)", devIdentityPubB64: "pk-\(name)")
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
        let mc = relayMC("h")
        m.machineStore.add(mc)
        let s1 = m.session(for: mc.id)
        let s2 = m.session(for: mc.id)
        XCTAssertTrue(s1 === s2)   // 缓存保活：同机器同一 Session 实例
    }

    func test_activeSessionFollowsActiveMachine() {
        let m = mgr()
        let a = relayMC("a"); m.machineStore.add(a)
        let b = relayMC("b"); m.machineStore.add(b)
        m.setActive(a.id)
        XCTAssertEqual(m.activeSession?.id, a.id)
        m.setActive(b.id)
        XCTAssertEqual(m.activeSession?.id, b.id)
    }

    func test_workspaceContextIsIsolatedAndSurvivesMachineSwitches() {
        let m = mgr()
        let a = relayMC("workspace-a"); m.machineStore.add(a)
        let b = relayMC("workspace-b"); m.machineStore.add(b)

        m.setActive(a.id)
        let stateA = m.activeSession!.workspaceState
        stateA.selectedThreadId = "thread-a"
        stateA.layout.showRight = true
        stateA.layout.showBottom = true
        stateA.bottomHeight = 321
        stateA.rightPanelTab = .files

        m.setActive(b.id)
        let stateB = m.activeSession!.workspaceState
        XCTAssertFalse(stateA === stateB)
        XCTAssertNil(stateB.selectedThreadId)
        XCTAssertFalse(stateB.layout.showRight)
        XCTAssertEqual(stateB.rightPanelTab, .review)
        stateB.selectedThreadId = "thread-b"

        m.setActive(a.id)
        XCTAssertTrue(m.activeSession!.workspaceState === stateA)
        XCTAssertEqual(stateA.selectedThreadId, "thread-a")
        XCTAssertTrue(stateA.layout.showRight)
        XCTAssertTrue(stateA.layout.showBottom)
        XCTAssertEqual(stateA.bottomHeight, 321)
        XCTAssertEqual(stateA.rightPanelTab, .files)
    }

    func test_removeDropsSessionAndMachine() async {
        let m = mgr()
        let mc = relayMC("h"); m.machineStore.add(mc)
        _ = m.session(for: mc.id)
        let result = await m.removeMachine(id: mc.id)
        XCTAssertEqual(result, .completed)
        XCTAssertTrue(m.machineStore.machines.isEmpty)
        XCTAssertNil(m.activeSession)
    }

    func test_removingActiveMachineActivatesAndConnectsReplacement() async {
        let store = MachineStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        let manager = SessionsManager(machineStore: store, transportFactory: { _ in MockTransport() })
        let a = relayMC("remove-active-a"); store.add(a)
        let b = relayMC("remove-active-b"); store.add(b)
        manager.setActive(a.id)

        let result = await manager.removeMachine(id: a.id)
        XCTAssertEqual(result, .completed)

        XCTAssertEqual(manager.activeSessionId, b.id)
        let replacement = manager.activeSession
        XCTAssertEqual(replacement?.id, b.id)
        XCTAssertEqual(replacement?.isForeground, true)
        XCTAssertNotEqual(replacement?.connection.phase, .disconnected)
    }

    /// Important#1 回归：removeMachine 必须真的断连缓存 session（防连接泄漏）。
    /// 旧实现 `Task { await cache[id]?.disconnect() }` + 同步 `cache[id] = nil`：闭包体延迟
    /// 执行时 cache[id] 已为 nil → 断连从不发生。
    /// 这里用**空 host** 让 connect 同步落 .failed（该守卫路径不起后台 establish Task，故无 race），
    /// 把 phase 确定性推离 .disconnected；removeMachine 后若断连真的发生，disconnect() 会把
    /// phase 拉回 .disconnected。buggy 版本断连不发生 → phase 卡在 .failed → RED。
    func test_removeMachineDisconnectsCachedSession() async {
        let m = mgr()
        let mc = relayMC("h"); m.machineStore.add(mc)
        let s = m.session(for: mc.id)!
        // 空 relayURL → connect 守卫同步落 .failed（无后台 Task，确定性推离 .disconnected）。
        s.connection.connect(config: ConnectionConfig(relayURL: "", relaySessionId: "", relayDevIdentityPubB64: ""))
        XCTAssertNotEqual(s.connection.phase, .disconnected, "前置：无效 connect 应同步落 .failed")

        let result = await m.removeMachine(id: mc.id)
        XCTAssertEqual(result, .completed)
        XCTAssertEqual(s.connection.phase, .disconnected,
                       "removeMachine 返回前应完成断连")
    }

    func test_removeMachineKeepsMachineAndSessionWhenSideChatInterruptFails() async {
        let mock = MockTransport()
        let store = MachineStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        let manager = SessionsManager(machineStore: store, transportFactory: { _ in mock })
        let machine = relayMC("remove-failure")
        XCTAssertTrue(store.add(machine))
        let session = manager.session(for: machine.id)!
        session.sideChat.setSessionsForTesting([
            SideChatSession(id: "hidden-running", forkedFromId: "main", title: "running")
        ], selectedId: nil)
        session.projects.handleStatusChanged(
            threadId: "hidden-running", status: .active(activeFlags: [])
        )

        let result = await manager.removeMachine(id: machine.id)

        XCTAssertEqual(result, .interruptFailed(["hidden-running"]))
        XCTAssertEqual(store.machines.map(\.id), [machine.id])
        XCTAssertTrue(manager.session(for: machine.id) === session)
        XCTAssertEqual(session.sideChat.sessions.map(\.id), ["hidden-running"])
    }

    /// #7 回前台自动重连（review 追加）：活跃 Session 的首连曾在后台被取消而落 .disconnected 后，
    /// app 回前台（setAppForegroundAll(true)）应按需重连该活跃 tab——phase 离开 .disconnected。
    /// 用 blockHandshake 的 MockTransport：connect() 起后台 establish Task 挂在握手，phase → .connecting；
    /// setForeground(false) 走 #7 路径取消在途首连并落 .disconnected（复现被后台取消的终态）；
    /// 再 setAppForegroundAll(true) → shouldAutoConnect(.disconnected)==true → connect() → 离开 .disconnected。
    func test_appForegroundReconnectsActiveDisconnectedSession() async {
        let mock = MockTransport()
        await mock.setBlockHandshake(true)
        let store = MachineStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        let m = SessionsManager(machineStore: store, transportFactory: { _ in mock })
        // 用 relay 机器：connect 守卫只需 relayURL 非空，绕开 SSH 的本机密钥前置（与 #7 的 relay 语境一致）。
        let mc = MachineConfig(displayName: "r", relayURL: "wss://x", sessionId: "s", devIdentityPubB64: "p")
        store.add(mc)
        m.setActive(mc.id)                          // 建活跃 Session 并懒连（phase → .connecting）
        let s = m.activeSession!
        // 等在途 transport 就位再退后台：phase 早于 inFlightTransport 赋值置 .connecting，
        // 若在 inFlightTransport==nil 窗口退后台，#7 取消分支不触发（与 ConnectionStoreTests 同）。
        _ = await waitUntil { s.connection.inFlightTransportForTesting != nil }

        s.connection.setForeground(false)           // #7：取消在途首连 → 落 .disconnected
        let landed = await waitUntil { s.connection.phase == .disconnected }
        XCTAssertTrue(landed, "前置：后台取消在途首连应落 .disconnected")

        m.setAppForegroundAll(true)                 // 回前台：应对活跃 tab 按需重连
        let reconnecting = await waitUntil { s.connection.phase != .disconnected }
        XCTAssertTrue(reconnecting,
                      "#7：回前台应对活跃 .disconnected 会话自动重连（离开 .disconnected）")
    }

    /// #7 边界：回前台**不得**对已就绪/连接中的活跃会话重复触发 connect（shouldAutoConnect==false）。
    /// 也不因回前台批量唤醒——此处以「连接中(.connecting)」为例：setAppForegroundAll(true) 不应改其 phase
    /// 或重发 connect（既有在途 establish 继续，不叠加新一次）。
    func test_appForegroundDoesNotReconnectActiveConnectingSession() async {
        let mock = MockTransport()
        await mock.setBlockHandshake(true)
        let store = MachineStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        let m = SessionsManager(machineStore: store, transportFactory: { _ in mock })
        let mc = MachineConfig(displayName: "r", relayURL: "wss://x", sessionId: "s", devIdentityPubB64: "p")
        store.add(mc)
        m.setActive(mc.id)
        let s = m.activeSession!
        _ = await waitUntil { s.connection.phase == .connecting }

        m.setAppForegroundAll(true)                 // 已在连接中：shouldAutoConnect==false，不重连
        // 给潜在的误触发一点调度窗口，随后仍应停在 .connecting（未被作废重来、未落 .disconnected）。
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(s.connection.phase, .connecting,
                       "#7：连接中的会话回前台不应被重复 connect 或改变 phase")
    }

    func test_manualDisconnectSurvivesTabAndAppLifecycleUntilExplicitConnect() async {
        let factory = IntentFactoryCounter()
        let store = MachineStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        let manager = SessionsManager(machineStore: store,
                                      transportFactory: { config in await factory.make(config) })
        let a = relayMC("a"); store.add(a)
        let b = relayMC("b"); store.add(b)

        manager.setActive(a.id)
        _ = await waitUntil { await factory.count(for: "s-a") == 1 }
        let sessionA = manager.session(for: a.id)!
        manager.disconnect(id: a.id)
        _ = await waitUntil { sessionA.connection.phase == .disconnected }
        XCTAssertTrue(sessionA.userPaused, "手动断开应记录用户暂停意图")

        manager.setActive(b.id)
        manager.setActive(a.id)
        manager.setAppForegroundAll(false)
        manager.setAppForegroundAll(true)
        try? await Task.sleep(for: .milliseconds(80))
        let afterLifecycle = await factory.count(for: "s-a")
        XCTAssertEqual(afterLifecycle, 1, "切 tab/回前台不得绕过用户暂停自动重连")
        XCTAssertTrue(manager.canConnect(id: a.id), "暂停态仍应显示显式连接入口")

        manager.connectMachine(id: a.id)
        _ = await waitUntil { await factory.count(for: "s-a") == 2 }
        let afterExplicitConnect = await factory.count(for: "s-a")
        XCTAssertEqual(afterExplicitConnect, 2, "显式连接应解除暂停并只新建一次连接")
        XCTAssertFalse(sessionA.userPaused)
    }


    /// （间接保证 workspace(for:) 注入路径依赖的 store 都存在，防未来漏注入）。
    /// 12 个均为非可选 let，故以 ObjectIdentifier 收集去重断言全部存在且互为独立实例。
    func test_activeSessionHasAllTwelveStoresWired() {
        let m = mgr()
        let mc = relayMC("h"); m.machineStore.add(mc)
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

    /// 设置入口结构回归：主界面和零机器引导页都必须可进入设置；配对表单不重复放入口。
    ///
    /// 说明：SwiftUI 的无障碍/视图树在 XCTest 无障碍技术未激活的无头环境下不会同步落地
    /// （实测 UIHostingController 采集 a11y label 恒空），故不用运行时快照，改用**源码级结构断言**：
    /// 齿轮以 `Image(systemName: "gearshape")` 呈现，`gearshape` 字面量是稳定标记。
    /// - 正向对照：RootSplitView 源码**必含** `gearshape`（证明扫描器确实能识别齿轮标记，
    ///   否则「引导页无齿轮」可能只是扫描器失效的假阳性）；
    func test_settingsGear_availableInWorkspaceAndOnboarding_notPairingForm() throws {
        let viewsDir = Self.viewsDirectory()
        let gearToken = "gearshape"

        // 正向对照：主界面 topBar 视图必含齿轮标记（扫描器有效性自证）。
        let rootSplit = try String(contentsOf: viewsDir.appendingPathComponent("RootSplitView.swift"), encoding: .utf8)
        XCTAssertTrue(rootSplit.contains(gearToken),
                      "RootSplitView 应含设置齿轮标记 \(gearToken)（正向对照：证明扫描器能识别齿轮）")

        let onboarding = try String(
            contentsOf: viewsDir.appendingPathComponent("OnboardingView.swift"), encoding: .utf8
        )
        XCTAssertTrue(onboarding.contains(gearToken), "零机器状态也必须能进入设置")

        let form = try String(
            contentsOf: viewsDir.appendingPathComponent("MachineFormView.swift"), encoding: .utf8
        )
        XCTAssertFalse(form.contains(gearToken), "配对表单不应重复提供设置入口")
    }

    // MARK: - Task 11 前后台策略（D6=B 保连降频）+ tab 圆点数据源

    /// D6：切活跃 tab 时旧前台转后台、新前台转前台。
    /// 后台 = stopPolling 降频；前台 = startPolling + refreshNow 补最终态（rpc 未注入时均为幂等 no-op）。
    func test_setActiveMovesOldToBackgroundNewToForeground() {
        let m = mgr()
        let a = relayMC("a"); m.machineStore.add(a)
        let b = relayMC("b"); m.machineStore.add(b)
        let sa = m.session(for: a.id)!
        let sb = m.session(for: b.id)!

        m.setActive(a.id)
        XCTAssertTrue(sa.isForeground, "新活跃 a 应转前台")
        XCTAssertTrue(sa.connection.tabActive, "活跃 tab 应使用活动心跳节奏")
        XCTAssertFalse(sb.isForeground, "b 从未活跃，仍在后台")
        XCTAssertFalse(sb.connection.tabActive, "非活动 tab 应使用低频心跳节奏")

        m.setActive(b.id)
        XCTAssertFalse(sa.isForeground, "旧前台 a 切走后应转后台")
        XCTAssertFalse(sa.connection.tabActive, "切走后应降为低频心跳")
        XCTAssertTrue(sb.isForeground, "新活跃 b 应转前台")
        XCTAssertTrue(sb.connection.tabActive, "切入后应恢复活动心跳节奏")
    }

    // MARK: - final C1 懒连/重连入口

    /// C1 核心：切到未连接（.disconnected）的 tab 应触发 connect（D7 懒连兑现）。
    /// 旧 setActive 只 setForeground、不发起 connect → 切过去停在 .disconnected（空工作区，无入口）。
    /// 修复后 setActive 对未连接 Session 调 connect() → phase 离开 .disconnected
    ///（有密钥走握手→.connecting；无密钥同步落 .failed；两者都证明 connect 确被调用）。
    func test_setActiveTriggersConnectForDisconnectedSession() async {
        let m = mgr()
        let a = relayMC("a"); m.machineStore.add(a)
        let b = relayMC("b"); m.machineStore.add(b)
        let sa = m.session(for: a.id)!                            // 建实例，phase == .disconnected
        XCTAssertEqual(sa.connection.phase, .disconnected, "前置：新建 Session 应为 .disconnected")

        m.setActive(a.id)
        let connected = await waitUntil { sa.connection.phase != .disconnected }
        XCTAssertTrue(connected, "切到未连接 tab 应触发 connect（phase 离开 .disconnected）")
    }

    /// C1：shouldAutoConnect 各 phase 语义——未连接/失败可（重）连，其余不重复触发。
    /// phase 为 private(set) 无法直接注入，故只覆盖初始可达的 .disconnected（true）；
    /// 连接中/就绪态的「不重复」由 test_setActiveDoesNotReconnect 覆盖行为。
    func test_shouldAutoConnect_trueWhenDisconnected() {
        let m = mgr()
        let mc = relayMC("a"); m.machineStore.add(mc)
        let s = m.session(for: mc.id)!
        XCTAssertEqual(s.connection.phase, .disconnected)
        XCTAssertTrue(s.shouldAutoConnect, "未连接 Session 应可（重）连")
    }

    /// C1：已连接（.ready）的 tab 再 setActive 不应重复 connect（shouldAutoConnect=false）。
    /// 先驱动握手到 .ready，再 setActive，验证不发生新连接（phase 仍稳定 .ready）。
    func test_setActiveDoesNotReconnectReadySession() async {
        let mock = MockTransport()
        let store = MachineStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        let m = SessionsManager(machineStore: store, transportFactory: { _ in mock })
        let mc = relayMC("a"); store.add(mc)
        let s = m.session(for: mc.id)!

        // 后台模拟服务端：收到 initialize 后回响应使握手到 .ready。
        Task {
            var initId: String?
            for _ in 0..<200 {
                try? await Task.sleep(nanoseconds: 5_000_000)
                if let sent = await mock.sent.first(where: { $0.contains(#""method":"initialize""#) }),
                   let obj = try? JSONSerialization.jsonObject(with: Data(sent.utf8)) as? [String: Any],
                   let id = obj["id"] as? String { initId = id; break }
            }
            if let initId {
                await mock.feed(#"{"jsonrpc":"2.0","id":"\#(initId)","result":{"userAgent":"codex","codexHome":"/x","platformFamily":"unix","platformOs":"macos"}}"#)
            }
        }
        s.connect()
        let ready = await waitUntil { s.connection.phase == .ready }
        XCTAssertTrue(ready, "前置：握手应到达 .ready")

        XCTAssertFalse(s.shouldAutoConnect, "已就绪不应再触发连接")
        m.setActive(mc.id)   // 再次切入不应重连
        // 短暂等待后 phase 仍应稳定为 .ready（未被重新拉回 .connecting）。
        let stayedReady = await waitUntil { s.connection.phase == .ready }
        XCTAssertTrue(stayedReady, "已就绪 tab 再 setActive 不应重复 connect（phase 稳定 .ready）")
    }

    /// C1：未 session(for:) 的机器 canConnect(id) == true（可从 tab 菜单发起首连）。
    func test_canConnect_trueForUnbuiltSession() {
        let m = mgr()
        let mc = relayMC("a"); m.machineStore.add(mc)
        // 刻意不建 Session：cache 无该 Session → canConnect 应回退 true。
        XCTAssertTrue(m.canConnect(id: mc.id), "未建 Session 的机器应可连（canConnect=true）")
    }

    /// D7 冷启动只连上次活跃：被连的那台就是启动前台 tab，应置前台。
    func test_bootstrapSetsActiveSessionForeground() {
        let m = mgr()
        let mc = relayMC("a"); m.machineStore.add(mc)
        m.bootstrapAutoConnect()
        let s = m.session(for: mc.id)!
        XCTAssertTrue(s.isForeground, "冷启动被连的活跃 tab 应为前台")
    }

    /// 圆点数据源：未建 Session（懒连未连）→ 无点（indicator 不应假连接）。
    func test_indicatorNoneForUnconnectedSession() {
        let m = mgr()
        let mc = relayMC("a"); m.machineStore.add(mc)
        // 刻意不调用 session(for:)：cache 无该 Session。
        XCTAssertEqual(m.indicator(for: mc.id), .none, "未建 Session 的 tab 应无圆点")
    }

    func testIndicatorThreadIdsIncludeEphemeralSideChatsAndDeduplicate() {
        XCTAssertEqual(
            SessionsManager.indicatorThreadIds(
                projectIds: ["main", "shared"], sideChatIds: ["side", "shared"]
            ),
            ["main", "side", "shared"]
        )
    }

    /// Task 9：已建 Session 但连接非就绪（phase != .ready）→ 灰点 .disconnected（红灰严格正交）。
    /// 新建 Session 默认 phase == .disconnected（非 .ready）。旧实现 resolve(isConnected:false) 恒 .none；
    /// 叠加「非 .ready → .disconnected」语义后应返回灰点，而非无点。
    /// 与 test_indicatorNoneForUnconnectedSession 区分：那条是**未建** Session（cache 空）→ .none；
    /// 这条是**已建**但连接异常 → .disconnected。
    func test_indicator_builtButNotReady_isDisconnected() {
        let m = mgr()
        let mc = relayMC("a"); m.machineStore.add(mc)
        let s = m.session(for: mc.id)!               // 建 Session，phase == .disconnected（非 .ready）
        XCTAssertNotEqual(s.connection.phase, .ready, "前置：新建 Session 应为非就绪")
        XCTAssertEqual(m.indicator(for: mc.id), .disconnected,
                       "已建但连接非就绪 → 灰点 .disconnected（红灰正交，非 .none）")
    }

    /// 圆点数据源（真实聚合）：已连接 Session 内有「待批准」活跃会话 → indicator 反映 .attention。
    /// 需驱动握手到 .ready（TabIndicator.resolve 未连接一律 .none），再经 ingest + handleStatusChanged
    /// 注入一个活跃会话状态，验证 indicator 从 projects 真实聚合而非桩恒 .none。
    func test_indicatorReflectsStatus() async throws {
        let mock = MockTransport()
        let store = MachineStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        let m = SessionsManager(machineStore: store, transportFactory: { _ in mock })
        let mc = relayMC("a"); store.add(mc)
        let s = m.session(for: mc.id)!

        // 后台模拟服务端：收到 initialize 后按其唯一 id 回响应，使握手到达 .ready。
        Task {
            var initId: String?
            for _ in 0..<200 {
                try? await Task.sleep(nanoseconds: 5_000_000)
                if let sent = await mock.sent.first(where: { $0.contains(#""method":"initialize""#) }),
                   let obj = try? JSONSerialization.jsonObject(with: Data(sent.utf8)) as? [String: Any],
                   let id = obj["id"] as? String { initId = id; break }
            }
            if let initId {
                await mock.feed(#"{"jsonrpc":"2.0","id":"\#(initId)","result":{"userAgent":"codex","codexHome":"/x","platformFamily":"unix","platformOs":"macos"}}"#)
            }
        }
        s.connect()
        let ready = await waitUntil { s.connection.phase == .ready }
        XCTAssertTrue(ready, "前置：握手应到达 .ready")

        // 注入一个活跃会话 + 待批准状态。
        s.projects.ingest([threadSummary(id: "t1", cwd: "", updatedAt: 100)])
        s.projects.handleStatusChanged(threadId: "t1", status: .active(activeFlags: [.waitingOnApproval]))
        XCTAssertEqual(m.indicator(for: mc.id), .attention,
                       "已连接 + 待批准活跃会话 → indicator 应聚合为 .attention")
    }

    /// 构造 loose 会话摘要（无 gitInfo）供圆点聚合测试注入。
    private func threadSummary(id: String, cwd: String, updatedAt: Double) -> ThreadSummary {
        ThreadSummary(id: id, sessionId: id, preview: "", modelProvider: "openai",
                      createdAt: 0, updatedAt: updatedAt, cwd: cwd, cliVersion: "0.133.0",
                      name: nil, gitInfo: nil)
    }

    /// Task 12 验收回归：切 tab 不串台（session 隔离 + 缓存保活 + store 隔离）。
    /// - a、b 两台机器的 Session 是不同实例；
    /// - setActive(a) 后 activeSession === session(a)；切到 b 后 activeSession === session(b)
    ///   且 a 的 Session 仍是原实例（缓存保活，未被 b 覆盖/污染）；
    /// - a.session.projects !== b.session.projects（各机器 store 隔离，切 tab 数据不互串）。
    func test_switchTabDoesNotBleedState() {
        let m = mgr()
        let a = relayMC("a"); m.machineStore.add(a)
        let b = relayMC("b"); m.machineStore.add(b)

        let sa = m.session(for: a.id)!
        let sb = m.session(for: b.id)!
        XCTAssertFalse(sa === sb, "两台机器的 Session 应为不同实例")

        m.setActive(a.id)
        XCTAssertTrue(m.activeSession === sa, "setActive(a) 后 activeSession 应为 a 的 Session")

        m.setActive(b.id)
        XCTAssertTrue(m.activeSession === sb, "setActive(b) 后 activeSession 应为 b 的 Session")
        XCTAssertTrue(m.session(for: a.id) === sa, "缓存保活：切到 b 后 a 的 Session 仍是原实例")

        XCTAssertFalse(sa.projects === sb.projects, "各机器 projects store 应隔离，切 tab 不串台")
    }

    // MARK: - fix-lifecycle-energy-leaks D1：app 级前后台正交广播

    func test_setAppForegroundAll_broadcastsToAllCachedSessions() {
        let m = mgr()
        let a = relayMC("a"); m.machineStore.add(a)
        let b = relayMC("b"); m.machineStore.add(b)
        let sa = m.session(for: a.id)!
        let sb = m.session(for: b.id)!
        m.setActive(a.id)
        XCTAssertTrue(sa.connection.foregroundActive, "前置：默认前台")
        XCTAssertTrue(sb.connection.foregroundActive, "前置：默认前台")
        m.setAppForegroundAll(false)
        XCTAssertFalse(sa.connection.foregroundActive, "活跃 Session 应收 app 后台")
        XCTAssertFalse(sb.connection.foregroundActive, "非活跃缓存 Session 也应收 app 后台（P1-1 修复点）")
        m.setAppForegroundAll(true)
        XCTAssertTrue(sa.connection.foregroundActive, "回前台应恢复")
        XCTAssertTrue(sb.connection.foregroundActive, "回前台应恢复")
    }

    func test_setAppForegroundAll_doesNotTouchTabForeground() {
        let m = mgr()
        let a = relayMC("a"); m.machineStore.add(a)
        let b = relayMC("b"); m.machineStore.add(b)
        let sa = m.session(for: a.id)!
        let sb = m.session(for: b.id)!
        m.setActive(a.id)
        XCTAssertTrue(sa.isForeground); XCTAssertFalse(sb.isForeground)
        m.setAppForegroundAll(false)
        XCTAssertTrue(sa.isForeground, "app 后台不得改 tab 级前台标记（正交）")
        XCTAssertFalse(sb.isForeground, "tab 级标记保持不变")
    }

    // MARK: - fix-lifecycle-energy-leaks D4：新增机器只建连一次

    private actor FactoryCounter {
        private(set) var count = 0
        func bump() { count += 1 }
    }

    private actor IntentFactoryCounter {
        private var counts: [String: Int] = [:]
        func make(_ config: ConnectionConfig) -> MockTransport {
            counts[config.relaySessionId, default: 0] += 1
            return MockTransport()
        }
        func count(for sessionId: String) -> Int { counts[sessionId, default: 0] }
    }

    func test_addMachineAndConnect_invokesFactoryExactlyOnce() async {
        let counter = FactoryCounter()
        let store = MachineStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        let m = SessionsManager(machineStore: store,
                                transportFactory: { _ in await counter.bump(); return MockTransport() })

        let mc = relayMC("a")
        m.addMachineAndConnect(mc)

        // 等第一次建连触发 factory（异步：connect → Task doEstablish → factory）。内联轮询。
        var got1 = false
        for _ in 0..<400 {
            if await counter.count >= 1 { got1 = true; break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(got1, "新增机器应触发一次建连")
        // 证伪：再给窗口，确认不会出现第二次建连（旧实现此处为 2）。
        try? await Task.sleep(nanoseconds: 300_000_000)
        let final = await counter.count
        XCTAssertEqual(final, 1, "新增机器 transport factory 只应被调用一次（不并行两套建连）")
    }

    func test_replaceMachine_preservesIdentityAndCount() async {
        let store = MachineStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        let manager = SessionsManager(
            machineStore: store,
            transportFactory: { _ in MockTransport() },
            resetPairingTrust: { _ in })
        let original = relayMC("old")
        XCTAssertTrue(store.add(original))
        let replacement = MachineConfig(
            id: original.id,
            displayName: original.displayName,
            relayURL: "wss://new.example/ws",
            sessionId: "new-session",
            devIdentityPubB64: "new-key")

        let result = await manager.replaceMachineAndConnect(replacement, pairingCode: "pair")
        XCTAssertEqual(result, .completed)

        XCTAssertEqual(store.machines.count, 1)
        XCTAssertEqual(store.machines.first?.id, original.id)
        XCTAssertEqual(store.machines.first?.sessionId, "new-session")
        XCTAssertEqual(manager.activeSessionId, original.id)
    }

    func test_replaceMachineKeepsOldConfigWhenSideChatInterruptFails() async {
        let mock = MockTransport()
        let store = MachineStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        let manager = SessionsManager(
            machineStore: store, transportFactory: { _ in mock }, resetPairingTrust: { _ in }
        )
        let original = relayMC("replace-failure")
        XCTAssertTrue(store.add(original))
        let session = manager.session(for: original.id)!
        session.sideChat.setSessionsForTesting([
            SideChatSession(id: "hidden-running", forkedFromId: "main", title: "running")
        ], selectedId: nil)
        session.projects.handleStatusChanged(
            threadId: "hidden-running", status: .active(activeFlags: [])
        )
        var replacement = original
        replacement.sessionId = "new-session"

        let result = await manager.replaceMachineAndConnect(replacement, pairingCode: "pair")

        XCTAssertEqual(result, .interruptFailed(["hidden-running"]))
        XCTAssertEqual(store.machines.first?.sessionId, original.sessionId)
        XCTAssertTrue(manager.session(for: original.id) === session)
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
                           _ condition: @MainActor () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)   // 5ms
        }
        return await condition()
    }
}
