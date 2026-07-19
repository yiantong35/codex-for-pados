import Foundation
import Observation

/// 多机器根容器：持有机器列表（MachineStore）、Session 缓存（保活）、活跃切换。
/// 后台策略（D6=B）：setActive 切换时把旧活跃 Session 转后台、新活跃转前台；
/// 前后台切换收放的是**列表轮询**（Session.setForeground → projects.startPolling/stopPolling），
/// A 类广播订阅（thread/status/changed）前后台恒常驻，故后台 tab 徽标仍 live。
@Observable
@MainActor
final class SessionsManager {
    let machineStore: MachineStore
    private let transportFactory: @Sendable (ConnectionConfig) async throws -> MessageTransport

    /// 缓存保活（D8）：每机器一个 Session，切走不销毁。
    private var cache: [UUID: Session] = [:]

    init(machineStore: MachineStore,
         transportFactory: @escaping @Sendable (ConnectionConfig) async throws -> MessageTransport) {
        self.machineStore = machineStore
        self.transportFactory = transportFactory
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
        if s.shouldAutoConnect { s.connect() }
    }

    /// 手动（重）连某机器（TabBarView contextMenu「连接」项用）。
    /// 用 session(for:)：若懒连从未切过去、Session 未建，会按需建实例再连。
    func connectMachine(id: UUID) {
        session(for: id)?.connect()
    }

    /// 是否可（重）连某机器：未在连接中且未就绪才显示「连接」入口。
    /// 未建 Session（懒连从未切过去）→ true（表示可连），避免为判断而提前建实例。
    func canConnect(id: UUID) -> Bool {
        cache[id]?.shouldAutoConnect ?? true
    }

    /// 添加机器后自动切过去并连接（D13）。
    @discardableResult
    func addMachineAndConnect(_ m: MachineConfig) -> Bool {
        guard machineStore.add(m) else { return false }
        setActive(m.id)
        session(for: m.id)?.connect()
        return true
    }

    func removeMachine(id: UUID) {
        // 先捕获 session 再清缓存：`Task{}` 体在 @MainActor 稍后调度，若先同步置 nil，
        // 闭包届时读到的 cache[id] 已为 nil → disconnect 短路、断连从不发生（连接泄漏）。
        let s = cache[id]
        cache[id] = nil
        machineStore.remove(id: id)
        Task { await s?.disconnect() }
    }

    func disconnect(id: UUID) {
        Task { await cache[id]?.disconnect() }
    }

    /// 冷启动只连上次活跃（D7）；其余懒连。被连的即启动前台 tab，置前台开轮询。
    func bootstrapAutoConnect() {
        guard let m = machineStore.lastActiveMachine else { return }
        machineStore.setActive(m.id)
        let s = session(for: m.id)
        s?.connect()
        s?.setForeground(true)
    }

    // MARK: - T7 UI 依赖桩（数据源/表单接线在 T11/T8 补）

    /// tab 圆点聚合状态（T11 真实实现）：从该 Session 的 projects 聚合会话状态 + 未读。
    /// 未建 Session（懒连未连）→ .none（符合「未连接无点」）。
    /// isSelected 传 false：tab 级聚合不针对单个选中会话。
    func indicator(for id: UUID) -> TabIndicator {
        guard let s = cache[id] else { return .none }   // 未建 Session（未连）→ 无点
        let connected = s.connection.phase == .ready
        let statuses = s.projects.allThreadsSorted.compactMap { s.projects.status(of: $0.id) }
        let hasUnread = s.projects.allThreadsSorted.contains { s.projects.hasUnread($0, isSelected: false) }
        return TabIndicator.resolve(isConnected: connected, statuses: statuses, hasUnread: hasUnread)
    }

    /// 添加机器表单呈现标志。T8 接表单 sheet（@Observable 类里普通存储属性自动可观察）。
    var addMachinePresented: Bool = false   // T8

    /// 触发添加机器表单。T8 接真实表单流程。
    func presentAddMachine() { addMachinePresented = true }   // T8
}
