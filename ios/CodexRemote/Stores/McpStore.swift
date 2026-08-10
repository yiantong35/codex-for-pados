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
    private(set) var loadState: ExtensionLoadState = .idle

    /// 折叠头计数徽章用（server 数）。
    var count: Int { servers.count }

    private var rpc: JSONRPCClient?
    private var observer: Task<Void, Never>?
    private var attachmentGeneration = 0
    private var refreshGeneration = 0

    /// 注入 rpc：拉初值 + 订阅通知。
    /// 同一 rpc 重复 attach 幂等；完整重连换新 rpc 实例时取消旧订阅并对新 rpc 重新订阅
    /// （否则新连接的 mcpServer/startupStatus/updated 推送刷新永久失效）。
    func attach(rpc: JSONRPCClient) async {
        let rpcChanged = self.rpc !== rpc
        if !rpcChanged, observer != nil { await refresh(); return }
        attachmentGeneration &+= 1
        let generation = attachmentGeneration
        self.rpc = rpc
        if rpcChanged { observer?.cancel(); observer = nil }
        let stream = await rpc.notifications(methods: [ServerNotificationMethod.mcpServerStatusUpdated])
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

    /// 拉取 server 列表（rpc 为 nil 时直接返回，不发请求）。
    func refresh() async {
        guard let rpc else { return }
        await refresh(using: rpc, generation: attachmentGeneration)
    }

    private func refresh(using rpc: JSONRPCClient, generation: Int) async {
        refreshGeneration &+= 1
        let refresh = refreshGeneration
        loadState = .loading
        guard let r: ListMcpServerStatusResponse =
            await sendDecode(rpc: rpc, RPCMethod.mcpServerStatusList, as: ListMcpServerStatusResponse.self)
        else {
            if generation == attachmentGeneration, refresh == refreshGeneration, self.rpc === rpc {
                loadState = .failed
            }
            return
        }
        guard generation == attachmentGeneration, refresh == refreshGeneration, self.rpc === rpc else { return }
        servers = r.data   // D5：nextCursor 忽略，不分页
        loadState = .loaded
    }

    /// 触发 desktop 端重载 MCP 配置。无返回体（D4）→ 完成后 refresh 兜底 + 等通知。
    func reload() async {
        guard let rpc else { return }
        let empty = try? JSONDecoder().decode(AnyCodable.self, from: Data("{}".utf8))
        do { _ = try await rpc.send(method: RPCMethod.mcpServerReload, params: empty) }
        catch { loadState = .failed; return }
        await refresh()
    }

    // MARK: 广播（internal 供单测）
    func applyBroadcast(_ n: JSONRPCNotification) {
        guard n.method == ServerNotificationMethod.mcpServerStatusUpdated else { return }
        Task { await refresh() }   // D4：整列重拉，不做单项 diff
    }

    // MARK: 私有
    private func sendDecode<T: Decodable>(rpc: JSONRPCClient, _ method: String, as: T.Type) async -> T? {
        let empty = (try? JSONDecoder().decode(AnyCodable.self, from: Data("{}".utf8)))
        guard let res = try? await rpc.send(method: method, params: empty),
              let rd = try? JSONEncoder().encode(res),
              let out = try? JSONDecoder().decode(T.self, from: rd) else { return nil }
        return out
    }
}
