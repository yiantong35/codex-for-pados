import Foundation
import Observation

/// 多机器根容器：持有机器列表（MachineStore）、Session 缓存（保活）、活跃切换。
/// 后台策略在 Task 11 接入（setActive 时收放订阅）；本任务先跑通单 tab。
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

    /// 切活跃 tab（后台策略钩子在 Task 11 补）。
    func setActive(_ id: UUID) {
        machineStore.setActive(id)
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

    /// 冷启动只连上次活跃（D7）；其余懒连。
    func bootstrapAutoConnect() {
        guard let m = machineStore.lastActiveMachine else { return }
        machineStore.setActive(m.id)
        session(for: m.id)?.connect()
    }

    // MARK: - T7 UI 依赖桩（数据源/表单接线在 T11/T8 补）

    /// tab 圆点聚合状态。T11 换成从 Session.projects 聚合 statuses + 未读的真实实现。
    func indicator(for id: UUID) -> TabIndicator { .none }   // T11

    /// 添加机器表单呈现标志。T8 接表单 sheet（@Observable 类里普通存储属性自动可观察）。
    var addMachinePresented: Bool = false   // T8

    /// 触发添加机器表单。T8 接真实表单流程。
    func presentAddMachine() { addMachinePresented = true }   // T8
}
