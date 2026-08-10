import Foundation
import Observation

enum ExtensionLoadState: Equatable {
    case idle, loading, loaded, failed
}

/// Skills 数据域（设计 D2）：只读展示本地 skills + 启用开关 + skills/changed 刷新。
/// attach/notifications/`self.rpc !== rpc` 重订阅模式克隆自 McpStore；与 McpStore/PluginsStore 并列，
/// 各自订阅同一 rpc.notifications() 流（现有架构支持多订阅者）。
@Observable
@MainActor
final class SkillsStore {
    private(set) var skills: [SkillMetadata] = []
    private(set) var loadState: ExtensionLoadState = .idle
    private(set) var pendingSkillIDs: Set<String> = []
    private(set) var failedSkillIDs: Set<String> = []

    /// 折叠头计数徽章用（skill 数）。
    var count: Int { skills.count }

    private var rpc: JSONRPCClient?
    private var observer: Task<Void, Never>?
    private var attachmentGeneration = 0
    private var refreshGeneration = 0

    /// 注入 rpc：拉初值 + 订阅 skills/changed。
    /// 同一 rpc 重复 attach 幂等；完整重连换新 rpc 实例时取消旧订阅并对新 rpc 重订阅
    /// （否则新连接的 skills/changed 刷新永久失效）。
    func attach(rpc: JSONRPCClient) async {
        let rpcChanged = self.rpc !== rpc
        if !rpcChanged, observer != nil { await refresh(); return }
        attachmentGeneration &+= 1
        let generation = attachmentGeneration
        self.rpc = rpc
        if rpcChanged { observer?.cancel(); observer = nil }
        let stream = await rpc.notifications(methods: [ServerNotificationMethod.skillsChanged])
        guard generation == attachmentGeneration, self.rpc === rpc else { return }
        observer = Task { [weak self] in
            for await n in stream {
                guard !Task.isCancelled else { break }
                let current = await MainActor.run {
                    guard let self,
                          self.attachmentGeneration == generation,
                          self.rpc === rpc else { return false }
                    self.applyBroadcast(n)
                    return true
                }
                if !current { break }
            }
        }
        await refresh(using: rpc, generation: generation)
    }

    /// 拉取 skills（rpc 为 nil 时不发请求）。首版不传 cwds（D5 fallback：发空参列全局）。
    /// 跨 cwd 打平 + 按 path 去重（避免 SwiftUI List 重复 id 崩溃）。
    func refresh() async {
        guard let rpc else { return }
        await refresh(using: rpc, generation: attachmentGeneration)
    }

    private func refresh(using rpc: JSONRPCClient, generation: Int) async {
        refreshGeneration &+= 1
        let refresh = refreshGeneration
        loadState = .loading
        do {
            let empty = try JSONDecoder().decode(AnyCodable.self, from: Data("{}".utf8))
            let res = try await rpc.send(method: RPCMethod.skillsList, params: empty)
            let rd = try JSONEncoder().encode(res)
            let out = try JSONDecoder().decode(SkillsListResponse.self, from: rd)
            guard generation == attachmentGeneration, refresh == refreshGeneration, self.rpc === rpc else { return }
            var seen = Set<String>()
            skills = out.data.flatMap { $0.skills }.filter { seen.insert($0.path).inserted }
            loadState = .loaded
        } catch {
            if generation == attachmentGeneration, refresh == refreshGeneration, self.rpc === rpc {
                loadState = .failed
            }
        }
    }

    func isUpdating(_ id: String) -> Bool { pendingSkillIDs.contains(id) }
    func writeFailed(_ id: String) -> Bool { failedSkillIDs.contains(id) }

    /// 切换 skill 启用态：立即乐观回显，单项写入期间禁用，失败仅回滚该项。
    func setEnabled(name: String?, path: String?, _ enabled: Bool) async {
        let id = path ?? name.map { "name:\($0)" } ?? ""
        guard !id.isEmpty, !pendingSkillIDs.contains(id) else { return }
        guard let rpc else {
            failedSkillIDs.insert(id)
            return
        }
        let index = skills.firstIndex { path != nil ? $0.path == path : $0.name == name }
        let previous = index.map { skills[$0].enabled }
        if let index { skills[index].enabled = enabled }
        pendingSkillIDs.insert(id)
        failedSkillIDs.remove(id)
        defer { pendingSkillIDs.remove(id) }

        let params = SkillsConfigWriteParams(enabled: enabled, name: name, path: path)
        guard let data = try? JSONEncoder().encode(params),
              let any = try? JSONDecoder().decode(AnyCodable.self, from: data) else {
            if let index, let previous { skills[index].enabled = previous }
            failedSkillIDs.insert(id)
            return
        }
        do {
            _ = try await rpc.send(method: RPCMethod.skillsConfigWrite, params: any)
        } catch {
            if let current = skills.firstIndex(where: { path != nil ? $0.path == path : $0.name == name }),
               let previous { skills[current].enabled = previous }
            failedSkillIDs.insert(id)
            return
        }
        await refresh()
    }

    // MARK: 广播（internal 供单测）
    func applyBroadcast(_ n: JSONRPCNotification) {
        guard n.method == ServerNotificationMethod.skillsChanged else { return }
        Task { await refresh() }   // D4：整列重拉
    }
}
