import Foundation
import Observation

private struct LossyMachineConfig: Decodable {
    let value: MachineConfig?

    init(from decoder: Decoder) throws {
        value = try? MachineConfig(from: decoder)
    }
}

/// 机器列表持久化（relay-only）+ 上限 10。
/// 凭据不在此管（relay pairing 串仅驻内存、编码时剥离，见 load()/persist()）。
@Observable
@MainActor
final class MachineStore {
    static let maxCount = 10

    private let defaults: UserDefaults
    private static let machinesKey = "machines"
    private static let activeKey = "activeMachineId"

    private(set) var machines: [MachineConfig] = []
    var activeMachineId: UUID?

    var canAddMore: Bool { machines.count < Self.maxCount }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
        if activeMachineId == nil { activeMachineId = machines.first?.id }
    }

    @discardableResult
    func add(_ m: MachineConfig) -> Bool {
        guard canAddMore else { return false }
        machines.append(m)
        persist()
        return true
    }

    func update(_ m: MachineConfig) {
        guard let idx = machines.firstIndex(where: { $0.id == m.id }) else { return }
        machines[idx] = m
        persist()
    }

    func remove(id: UUID) {
        machines.removeAll { $0.id == id }
        if activeMachineId == id { activeMachineId = machines.first?.id }
        persist()
    }

    func setActive(_ id: UUID) {
        activeMachineId = id
        if let idx = machines.firstIndex(where: { $0.id == id }) {
            machines[idx].lastActiveAt = Date()
        }
        persist()
    }

    /// 上次活跃机器（D7 冷启动只连它）。无标记时取列表首项。
    var lastActiveMachine: MachineConfig? {
        if let id = activeMachineId, let m = machines.first(where: { $0.id == id }) { return m }
        return machines.max { ($0.lastActiveAt ?? .distantPast) < ($1.lastActiveAt ?? .distantPast) }
            ?? machines.first
    }

    private func load() {
        if let data = defaults.data(forKey: Self.machinesKey),
           let decoded = try? JSONDecoder().decode([LossyMachineConfig].self, from: data) {
            let valid = decoded.compactMap(\.value)
            machines = valid

            // 非空输入若全都无效，保留原始数据，避免一次兼容性问题造成不可恢复的数据清空。
            if decoded.isEmpty || !valid.isEmpty,
               let normalized = try? JSONEncoder().encode(valid), normalized != data {
                defaults.set(normalized, forKey: Self.machinesKey)
            }
        }
        if let s = defaults.string(forKey: Self.activeKey) { activeMachineId = UUID(uuidString: s) }
        if let activeMachineId, !machines.contains(where: { $0.id == activeMachineId }) {
            self.activeMachineId = machines.first?.id
            persistActiveMachineID()
        }
    }

    private func persistActiveMachineID() {
        if let activeMachineId {
            defaults.set(activeMachineId.uuidString, forKey: Self.activeKey)
        } else {
            defaults.removeObject(forKey: Self.activeKey)
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(machines) {
            defaults.set(data, forKey: Self.machinesKey)
        }
        persistActiveMachineID()
    }
}
