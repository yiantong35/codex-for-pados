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

    // MARK: - Task 11 前后台策略（D6=B 保连降频）+ tab 圆点数据源

    /// D6：切活跃 tab 时旧前台转后台、新前台转前台。
    /// 后台 = stopPolling 降频；前台 = startPolling + refreshNow 补最终态（rpc 未注入时均为幂等 no-op）。
    func test_setActiveMovesOldToBackgroundNewToForeground() {
        let m = mgr()
        let a = MachineConfig(host: "a", user: "u"); m.machineStore.add(a)
        let b = MachineConfig(host: "b", user: "u"); m.machineStore.add(b)
        let sa = m.session(for: a.id)!
        let sb = m.session(for: b.id)!

        m.setActive(a.id)
        XCTAssertTrue(sa.isForeground, "新活跃 a 应转前台")
        XCTAssertFalse(sb.isForeground, "b 从未活跃，仍在后台")

        m.setActive(b.id)
        XCTAssertFalse(sa.isForeground, "旧前台 a 切走后应转后台")
        XCTAssertTrue(sb.isForeground, "新活跃 b 应转前台")
    }

    // MARK: - final C1 懒连/重连入口

    /// C1 核心：切到未连接（.disconnected）的 tab 应触发 connect（D7 懒连兑现）。
    /// 旧 setActive 只 setForeground、不发起 connect → 切过去停在 .disconnected（空工作区，无入口）。
    /// 修复后 setActive 对未连接 Session 调 connect() → phase 离开 .disconnected
    ///（有密钥走握手→.connecting；无密钥同步落 .failed；两者都证明 connect 确被调用）。
    func test_setActiveTriggersConnectForDisconnectedSession() async {
        await MainActor.run { KeyManager().generateIfNeeded() }   // 越过 connect 的密钥前置校验，稳定走 .connecting
        let m = mgr()
        let a = MachineConfig(host: "a", user: "u"); m.machineStore.add(a)
        let b = MachineConfig(host: "b", user: "u"); m.machineStore.add(b)
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
        let mc = MachineConfig(host: "a", user: "u"); m.machineStore.add(mc)
        let s = m.session(for: mc.id)!
        XCTAssertEqual(s.connection.phase, .disconnected)
        XCTAssertTrue(s.shouldAutoConnect, "未连接 Session 应可（重）连")
    }

    /// C1：已连接（.ready）的 tab 再 setActive 不应重复 connect（shouldAutoConnect=false）。
    /// 先驱动握手到 .ready，再 setActive，验证不发生新连接（phase 仍稳定 .ready）。
    func test_setActiveDoesNotReconnectReadySession() async {
        await MainActor.run { KeyManager().generateIfNeeded() }
        let mock = MockTransport()
        let store = MachineStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        let m = SessionsManager(machineStore: store, transportFactory: { _ in mock })
        let mc = MachineConfig(host: "a", user: "u"); store.add(mc)
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
        let mc = MachineConfig(host: "a", user: "u"); m.machineStore.add(mc)
        // 刻意不建 Session：cache 无该 Session → canConnect 应回退 true。
        XCTAssertTrue(m.canConnect(id: mc.id), "未建 Session 的机器应可连（canConnect=true）")
    }

    /// D7 冷启动只连上次活跃：被连的那台就是启动前台 tab，应置前台。
    func test_bootstrapSetsActiveSessionForeground() {
        let m = mgr()
        let mc = MachineConfig(host: "a", user: "u"); m.machineStore.add(mc)
        m.bootstrapAutoConnect()
        let s = m.session(for: mc.id)!
        XCTAssertTrue(s.isForeground, "冷启动被连的活跃 tab 应为前台")
    }

    /// 圆点数据源：未建 Session（懒连未连）→ 无点（indicator 不应假连接）。
    func test_indicatorNoneForUnconnectedSession() {
        let m = mgr()
        let mc = MachineConfig(host: "a", user: "u"); m.machineStore.add(mc)
        // 刻意不调用 session(for:)：cache 无该 Session。
        XCTAssertEqual(m.indicator(for: mc.id), .none, "未建 Session 的 tab 应无圆点")
    }

    /// 圆点数据源（真实聚合）：已连接 Session 内有「待批准」活跃会话 → indicator 反映 .attention。
    /// 需驱动握手到 .ready（TabIndicator.resolve 未连接一律 .none），再经 ingest + handleStatusChanged
    /// 注入一个活跃会话状态，验证 indicator 从 projects 真实聚合而非桩恒 .none。
    func test_indicatorReflectsStatus() async throws {
        await MainActor.run { KeyManager().generateIfNeeded() }   // 越过 connect 的密钥前置校验
        let mock = MockTransport()
        let store = MachineStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        let m = SessionsManager(machineStore: store, transportFactory: { _ in mock })
        let mc = MachineConfig(host: "a", user: "u"); store.add(mc)
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
        s.projects.ingest([threadSummary(id: "t1", cwd: "/repo", updatedAt: 100)])
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
        let a = MachineConfig(host: "a", user: "u"); m.machineStore.add(a)
        let b = MachineConfig(host: "b", user: "u"); m.machineStore.add(b)

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
        let a = MachineConfig(host: "a", user: "u"); m.machineStore.add(a)
        let b = MachineConfig(host: "b", user: "u"); m.machineStore.add(b)
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
        let a = MachineConfig(host: "a", user: "u"); m.machineStore.add(a)
        let b = MachineConfig(host: "b", user: "u"); m.machineStore.add(b)
        let sa = m.session(for: a.id)!
        let sb = m.session(for: b.id)!
        m.setActive(a.id)
        XCTAssertTrue(sa.isForeground); XCTAssertFalse(sb.isForeground)
        m.setAppForegroundAll(false)
        XCTAssertTrue(sa.isForeground, "app 后台不得改 tab 级前台标记（正交）")
        XCTAssertFalse(sb.isForeground, "tab 级标记保持不变")
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
