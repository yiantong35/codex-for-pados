import Foundation
import Observation

/// MCP 数据域（设计 D2）：只读展示当前 daemon 上的 MCP server + 一键 reload。
/// 独立于 EnvironmentStore（职责分离），与 EnvironmentStore/ProjectsStore 并列，
/// 各自订阅同一 rpc.notifications() 流（现有架构支持多订阅者）。
/// attach/notifications/sendDecode 幂等模式克隆自 EnvironmentStore。
@Observable
@MainActor
final class McpStore {
    private(set) var servers: [McpServerStatus] = []

    private var rpc: JSONRPCClient?
    private var observer: Task<Void, Never>?

    /// 注入 rpc：拉初值 + 订阅通知。
    /// 同一 rpc 重复 attach 幂等；完整重连换新 rpc 实例时取消旧订阅并对新 rpc 重新订阅
    /// （否则新连接的 mcpServer/startupStatus/updated 推送刷新永久失效）。
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

    /// 拉取 server 列表（rpc 为 nil 时直接返回，不发请求）。
    func refresh() async {
        guard let r: ListMcpServerStatusResponse =
            await sendDecode(RPCMethod.mcpServerStatusList, as: ListMcpServerStatusResponse.self)
        else { return }
        servers = r.data   // D5：nextCursor 忽略，不分页
    }

    /// 触发 desktop 端重载 MCP 配置。无返回体（D4）→ 完成后 refresh 兜底 + 等通知。
    func reload() async {
        guard let rpc else { return }
        let empty = try? JSONDecoder().decode(AnyCodable.self, from: Data("{}".utf8))
        _ = try? await rpc.send(method: RPCMethod.mcpServerReload, params: empty)
        await refresh()
    }

    // MARK: 广播（internal 供单测）
    func applyBroadcast(_ n: JSONRPCNotification) {
        guard n.method == ServerNotificationMethod.mcpServerStatusUpdated else { return }
        Task { await refresh() }   // D4：整列重拉，不做单项 diff
    }

    // MARK: 私有
    private func sendDecode<T: Decodable>(_ method: String, as: T.Type) async -> T? {
        guard let rpc else { return nil }
        let empty = (try? JSONDecoder().decode(AnyCodable.self, from: Data("{}".utf8)))
        guard let res = try? await rpc.send(method: method, params: empty),
              let rd = try? JSONEncoder().encode(res),
              let out = try? JSONDecoder().decode(T.self, from: rd) else { return nil }
        return out
    }
}
