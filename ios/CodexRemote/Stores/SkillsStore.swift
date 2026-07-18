import Foundation
import Observation

/// Skills 数据域（设计 D2）：只读展示本地 skills + 启用开关 + skills/changed 刷新。
/// attach/notifications/`self.rpc !== rpc` 重订阅模式克隆自 McpStore；与 McpStore/PluginsStore 并列，
/// 各自订阅同一 rpc.notifications() 流（现有架构支持多订阅者）。
@Observable
@MainActor
final class SkillsStore {
    private(set) var skills: [SkillMetadata] = []

    /// 折叠头计数徽章用（skill 数）。
    var count: Int { skills.count }

    private var rpc: JSONRPCClient?
    private var observer: Task<Void, Never>?

    /// 注入 rpc：拉初值 + 订阅 skills/changed。
    /// 同一 rpc 重复 attach 幂等；完整重连换新 rpc 实例时取消旧订阅并对新 rpc 重订阅
    /// （否则新连接的 skills/changed 刷新永久失效）。
    func attach(rpc: JSONRPCClient) async {
        let rpcChanged = self.rpc !== rpc
        self.rpc = rpc
        await refresh()
        if rpcChanged { observer?.cancel(); observer = nil }
        guard observer == nil else { return }
        let stream = await rpc.notifications()
        observer = Task { [weak self] in
            for await n in stream { await MainActor.run { self?.applyBroadcast(n) } }
        }
    }

    /// 拉取 skills（rpc 为 nil 时不发请求）。首版不传 cwds（D5 fallback：发空参列全局）。
    /// 跨 cwd 打平 + 按 path 去重（避免 SwiftUI List 重复 id 崩溃）。
    func refresh() async {
        guard let rpc else { return }
        let empty = try? JSONDecoder().decode(AnyCodable.self, from: Data("{}".utf8))
        guard let res = try? await rpc.send(method: RPCMethod.skillsList, params: empty),
              let rd = try? JSONEncoder().encode(res),
              let out = try? JSONDecoder().decode(SkillsListResponse.self, from: rd)
        else { return }
        var seen = Set<String>()
        skills = out.data.flatMap { $0.skills }.filter { seen.insert($0.path).inserted }
    }

    /// 切换 skill 启用态：skills/config/write 后 refresh 兜底（D4；首版不做乐观回显）。
    func setEnabled(name: String?, path: String?, _ enabled: Bool) async {
        guard let rpc else { return }
        let params = SkillsConfigWriteParams(enabled: enabled, name: name, path: path)
        guard let data = try? JSONEncoder().encode(params),
              let any = try? JSONDecoder().decode(AnyCodable.self, from: data) else { return }
        _ = try? await rpc.send(method: RPCMethod.skillsConfigWrite, params: any)
        await refresh()
    }

    // MARK: 广播（internal 供单测）
    func applyBroadcast(_ n: JSONRPCNotification) {
        guard n.method == ServerNotificationMethod.skillsChanged else { return }
        Task { await refresh() }   // D4：整列重拉
    }
}
