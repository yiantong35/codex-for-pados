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
        Task { await cache[id]?.disconnect() }
        cache[id] = nil
        machineStore.remove(id: id)
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
}
