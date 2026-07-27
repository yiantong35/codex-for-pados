import Foundation
import Observation

/// 机器列表持久化（替换旧单组 UserDefaults key）+ 旧配置一次性迁移 + 上限 10。
/// 密钥不在此管（Keychain / KeyManager，一把公钥通用）。
@Observable
@MainActor
final class MachineStore {
    static let maxCount = 10

    private let defaults: UserDefaults
    private static let machinesKey = "machines"
    private static let activeKey = "activeMachineId"
    private static let legacyHost = "host", legacyUser = "sshUser", legacyPort = "sshPort"

    private(set) var machines: [MachineConfig] = []
    var activeMachineId: UUID?

    var canAddMore: Bool { machines.count < Self.maxCount }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
        if machines.isEmpty { migrateLegacyIfNeeded() }
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
           let list = try? JSONDecoder().decode([MachineConfig].self, from: data) {
            machines = list
            // 首次读取即自愈：若磁盘字节与规范化编码不一致（旧/非规范格式，如 relay 的
            // pairing 串仍含明文 pc），立即回写剥离后的规范 JSON，使磁盘不再滞留 pairingCode。
            // encode 只写非密三字段；重写后字节一致，后续启动不再触发（幂等）。
            if let normalized = try? JSONEncoder().encode(machines), normalized != data {
                defaults.set(normalized, forKey: Self.machinesKey)
            }
        }
        if let s = defaults.string(forKey: Self.activeKey) { activeMachineId = UUID(uuidString: s) }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(machines) {
            defaults.set(data, forKey: Self.machinesKey)
        }
        defaults.set(activeMachineId?.uuidString, forKey: Self.activeKey)
    }

    /// 旧单组配置 → 机器列表首项（仅当 machines 为空时）。旧 key 不删。
    private func migrateLegacyIfNeeded() {
        guard let host = defaults.string(forKey: Self.legacyHost), !host.isEmpty else { return }
        let user = defaults.string(forKey: Self.legacyUser) ?? ""
        let port = Int(defaults.string(forKey: Self.legacyPort) ?? "22") ?? 22
        let m = MachineConfig(host: host, user: user, sshPort: port)
        machines = [m]
        activeMachineId = m.id
        persist()
    }
}
