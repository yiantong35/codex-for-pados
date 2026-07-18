import Foundation
import Observation

/// Plugins 数据域（设计 D2/D6）：只读展示插件（按 marketplace 分组）+ 三级下钻读内置 skill 正文。
/// plugin 无 changed 通知，attach 仅存 rpc + refresh，不订阅。
@Observable
@MainActor
final class PluginsStore {
    private(set) var marketplaces: [PluginMarketplaceEntry] = []

    /// 折叠头计数徽章用（跨 marketplace 打平后的插件总数）。
    var count: Int { Self.count(of: marketplaces) }

    /// 跨 marketplace 求插件总数（纯函数供单测；nonisolated 便于同步调用）。
    nonisolated static func count(of marketplaces: [PluginMarketplaceEntry]) -> Int {
        marketplaces.reduce(0) { $0 + $1.plugins.count }
    }

    private var rpc: JSONRPCClient?

    /// 注入 rpc + 拉初值（幂等：同一/新 rpc 都只是覆盖引用后重拉）。
    func attach(rpc: JSONRPCClient) async {
        self.rpc = rpc
        await refresh()
    }

    /// 拉取插件列表（rpc 为 nil 时不发请求）。首版不传 cwds（D5 fallback）。
    func refresh() async {
        guard let out: PluginListResponse =
            await send(RPCMethod.pluginList, params: EmptyParams(), as: PluginListResponse.self)
        else { return }
        marketplaces = out.marketplaces
    }

    /// 下钻二级：读插件详情（含内置 skills[]）。plugin/read{pluginName, remoteMarketplaceName}（D6）。
    func readPluginDetail(pluginName: String, marketplace: String) async -> PluginDetail? {
        let params = PluginReadParams(pluginName: pluginName, remoteMarketplaceName: marketplace)
        return await send(RPCMethod.pluginRead, params: params, as: PluginReadResponse.self)?.plugin
    }

    /// 下钻三级：读某内置 skill 正文。plugin/skill/read{remoteMarketplaceName, remotePluginId, skillName}（D6）。
    func readPluginSkill(marketplace: String, pluginId: String, skillName: String) async -> String? {
        let params = PluginSkillReadParams(
            remoteMarketplaceName: marketplace, remotePluginId: pluginId, skillName: skillName)
        return await send(RPCMethod.pluginSkillRead, params: params, as: PluginSkillReadResponse.self)?.contents
    }

    // MARK: 私有
    /// 空参占位（编码为 `{}`）。
    private struct EmptyParams: Encodable {}

    /// 编码 params → 发请求 → 解码 response（rpc 为 nil 或任一步失败返回 nil）。
    private func send<P: Encodable, T: Decodable>(_ method: String, params: P, as: T.Type) async -> T? {
        guard let rpc,
              let data = try? JSONEncoder().encode(params),
              let any = try? JSONDecoder().decode(AnyCodable.self, from: data),
              let res = try? await rpc.send(method: method, params: any),
              let rd = try? JSONEncoder().encode(res),
              let out = try? JSONDecoder().decode(T.self, from: rd)
        else { return nil }
        return out
    }
}
