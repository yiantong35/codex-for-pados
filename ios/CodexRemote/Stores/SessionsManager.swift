import Foundation
import Observation

/// 多机器根容器：持有机器列表（MachineStore）、Session 缓存（保活）、活跃切换。
/// 后台策略（D6=B）：setActive 切换时把旧活跃 Session 转后台、新活跃转前台；
/// 前后台切换收放的是**列表轮询**（Session.setForeground → projects.startPolling/stopPolling），
/// A 类广播订阅（thread/status/changed）前后台恒常驻，故后台 tab 徽标仍 live。
@Observable
@MainActor
final class SessionsManager {
    enum DestructiveResult: Equatable {
        case completed
        case interruptFailed([String])
        case failed
    }
    let machineStore: MachineStore
    private let transportFactory: @Sendable (ConnectionConfig) async throws -> MessageTransport
    private let resetPairingTrust: @Sendable (UUID) throws -> Void

    /// 缓存保活（D8）：每机器一个 Session，切走不销毁。
    private var cache: [UUID: Session] = [:]

    init(machineStore: MachineStore,
         transportFactory: @escaping @Sendable (ConnectionConfig) async throws -> MessageTransport,
         resetPairingTrust: @escaping @Sendable (UUID) throws -> Void = { id in
             try KeychainTOFUStore().forget(machineKey: id.uuidString)
             UserDefaultsStableSessionStore().remove(machineKey: id.uuidString)
         }) {
        self.machineStore = machineStore
        self.transportFactory = transportFactory
        self.resetPairingTrust = resetPairingTrust
    }

    var activeSessionId: UUID? { machineStore.activeMachineId }

    var activeSession: Session? {
        guard let id = activeSessionId, machineStore.machines.contains(where: { $0.id == id })
        else { return nil }
        return session(for: id)
    }

    /// 取（或建）某机器的 Session（缓存保活）。
    func session(for id: UUID) -> Session? {
        if let s = cache[id] { return s }
        guard let m = machineStore.machines.first(where: { $0.id == id }) else { return nil }
        let s = Session(machine: m, transportFactory: transportFactory)
        cache[id] = s
        return s
    }

    /// 切活跃 tab（D6=B 后台策略）：旧活跃转后台（停轮询降频），新活跃转前台（开轮询 + 补最终态）。
    /// A 类广播订阅前后台都保留，后台机器状态变化仍实时更新 tab 圆点。
    func setActive(_ id: UUID) {
        // machineStore.activeMachineId 此刻仍是「旧」active（下一行才切）。
        if let oldId = machineStore.activeMachineId, oldId != id {
            cache[oldId]?.setForeground(false)   // 旧前台转后台
        }
        machineStore.setActive(id)
        guard let s = session(for: id) else { return }
        s.setForeground(true)                    // 新前台
        // 懒连（D7）：切到尚未连接/已断开/失败的 tab 时发起连接；连接中/已就绪不重复触发。
        s.autoConnect()
    }

    /// 手动（重）连某机器（TabBarView contextMenu「连接」项用）。
    /// 用 session(for:)：若懒连从未切过去、Session 未建，会按需建实例再连。
    func connectMachine(id: UUID) {
        setConnectionIntent(.automatic, for: id)
        session(for: id)?.connect()
    }

    /// 是否可（重）连某机器：未在连接中且未就绪才显示「连接」入口。
    /// 未建 Session（懒连从未切过去）→ true（表示可连），避免为判断而提前建实例。
    func canConnect(id: UUID) -> Bool {
        cache[id]?.canConnectManually ?? true
    }

    /// 添加机器后自动切过去并连接（D13）。
    /// setActive 内 `autoConnect()` 已负责懒连（新增机器 Session 初始 .disconnected，且未被用户
    /// 暂停），故此处不再重复 connect（能耗 D4）。
    @discardableResult
    func addMachineAndConnect(_ m: MachineConfig) -> Bool {
        guard machineStore.add(m) else { return false }
        setActive(m.id)
        return true
    }

    /// 重新配对当前机器：保留 machine id/列表位置，清除旧 TOFU 与稳定会话，再用新载荷重建连接。
    @discardableResult
    func replaceMachineAndConnect(_ m: MachineConfig, pairingCode: String) async -> DestructiveResult {
        guard machineStore.machines.contains(where: { $0.id == m.id }) else { return .failed }
        let oldSession = cache[m.id]
        if let oldSession {
            let cleanup = await oldSession.clearSensitiveTransientState()
            if case .interruptFailed(let ids) = cleanup { return .interruptFailed(ids) }
        }
        do { try resetPairingTrust(m.id) } catch { return .failed }

        cache[m.id] = nil
        machineStore.update(m)
        PendingPairingStore.shared.stash(pairingCode, for: m.id)
        setActive(m.id)
        await oldSession?.disconnect()
        return .completed
    }

    func removeMachine(id: UUID) async -> DestructiveResult {
        // 先捕获 session 再清缓存：`Task{}` 体在 @MainActor 稍后调度，若先同步置 nil，
        // 闭包届时读到的 cache[id] 已为 nil → disconnect 短路、断连从不发生（连接泄漏）。
        let s = cache[id]
        if let s {
            let cleanup = await s.clearSensitiveTransientState()
            if case .interruptFailed(let ids) = cleanup { return .interruptFailed(ids) }
        }
        let removedActiveMachine = machineStore.activeMachineId == id
        s?.setForeground(false)
        cache[id] = nil
        machineStore.remove(id: id)
        // MachineStore 会选出相邻机器，但只有 setActive 才会创建/前台化 Session 并触发懒连。
        if removedActiveMachine, let nextId = machineStore.activeMachineId {
            setActive(nextId)
        }
        await s?.disconnect()
        return .completed
    }

    /// 重命名某机器 tab 的显示名（TabBarView ⋯ 菜单「重命名」项用）。
    /// 空白名忽略（保持原名）；仅改持久化的 displayName，不动连接。
    func rename(id: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var m = machineStore.machines.first(where: { $0.id == id }) else { return }
        m.displayName = trimmed
        machineStore.update(m)
    }

    func disconnect(id: UUID) {
        setConnectionIntent(.disconnectedByUser, for: id)
        Task { await cache[id]?.disconnect() }
    }

    /// 冷启动只连上次活跃（D7）；其余懒连。被连的即启动前台 tab，置前台开轮询。
    func bootstrapAutoConnect() {
        guard let m = machineStore.lastActiveMachine else { return }
        machineStore.setActive(m.id)
        let s = session(for: m.id)
        s?.autoConnect()
        s?.setForeground(true)
    }

    /// app 级前后台广播（D1）：遍历**全部缓存 Session**（不止当前活跃 tab）转发 app 级前后台，
    /// 使每个连接的 transport 在 app 后台暂停重连/握手、回前台恢复。与 tab 级切换（setActive
    /// 的轮询开关）正交，不改任何 tab 的 isForeground / 轮询。
    /// #7：回前台时，若**当前活跃** Session 的首连曾在后台被取消而落 .disconnected/.failed
    /// （setForeground(false) 主动暂停在途首连的终态），此处按需重连——与 setActive 的懒连同构
    /// （`autoConnect()` 尊重连接状态及用户暂停：连接中/已就绪不重复触发，主动 disconnect 不重连），
    /// 仅限活跃 tab 一条连接（能耗 D4，不批量唤醒后台 tab）。使 spec「回前台重试成功」真正自动生效。
    func setAppForegroundAll(_ active: Bool) {
        for s in cache.values { s.setAppForeground(active) }
        if active { activeSession?.autoConnect() }
    }

    private func setConnectionIntent(_ intent: ConnectionIntent, for id: UUID) {
        guard var machine = machineStore.machines.first(where: { $0.id == id }) else { return }
        machine.connectionIntent = intent
        machineStore.update(machine)
        cache[id]?.updateMachine(machine)
    }

    // MARK: - T7 UI 依赖桩（数据源/表单接线在 T11/T8 补）

    /// tab 圆点聚合状态（T11 真实实现）：从该 Session 的 projects 聚合会话状态 + 未读。
    /// 未建 Session（懒连未连）→ .none（符合「未连接无点」）。
    /// isSelected 传 false：tab 级聚合不针对单个选中会话。
    func indicator(for id: UUID) -> TabIndicator {
        guard let s = cache[id] else { return .none }   // 未建 Session（未连）→ 无点
        // 已建但连接非就绪 → 灰点（连接异常）。红灰严格正交：灰点只在此上层给出，
        // resolve 仅在 .ready 前提下评估会话状态（红点仅由 systemError 在已连接时触发），
        // 未连接态绝不产生红点。
        guard s.connection.phase == .ready else { return .disconnected }
        let threadIds = Self.indicatorThreadIds(
            projectIds: s.projects.allThreadsSorted.map(\.id),
            sideChatIds: s.sideChat.sessions.map(\.id)
        )
        let statuses = threadIds.compactMap { s.projects.status(of: $0) }
        let hasUnread = s.projects.allThreadsSorted.contains { s.projects.hasUnread($0, isSelected: false) }
        return TabIndicator.resolve(isConnected: true, statuses: statuses, hasUnread: hasUnread)
    }

    static func indicatorThreadIds(projectIds: [String], sideChatIds: [String]) -> Set<String> {
        Set(projectIds + sideChatIds)
    }

    /// 添加机器表单呈现标志。T8 接表单 sheet（@Observable 类里普通存储属性自动可观察）。
    var addMachinePresented: Bool = false   // T8

    /// 触发添加机器表单。T8 接真实表单流程。
    func presentAddMachine() { addMachinePresented = true }   // T8

    // MARK: - T10 快捷键 tab 切换助手

    /// ⌘1..⌘9：切到机器数组第 index+1 项（0-based）。超界无副作用（spec）。
    func activateTab(atIndex index: Int) {
        guard index >= 0, index < machineStore.machines.count else { return }
        setActive(machineStore.machines[index].id)
    }

    /// ⌘] / ⌘[：相对当前活跃项移动 delta（+1 下一 / -1 上一）。越界无副作用、不循环（spec）。
    func activateAdjacentTab(delta: Int) {
        guard let cur = machineStore.machines.firstIndex(where: { $0.id == activeSessionId }) else { return }
        let next = cur + delta
        guard next >= 0, next < machineStore.machines.count else { return }
        setActive(machineStore.machines[next].id)
    }
}
