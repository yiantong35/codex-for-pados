import Foundation
import Observation

/// Hooks 数据域（设计 D4）：只读展示当前连接 daemon 上配置的生命周期钩子。
/// 协议无 hook 写方法、无 hooks/changed 通知 → attach 仅存 rpc + refresh，不订阅（比 PluginsStore 更简）。
@Observable
@MainActor
final class HooksStore {
    /// 跨 cwd 打平 + 按 key 去重后的 hooks（见 flatten）。
    private(set) var hooks: [HookMetadata] = []

    /// 折叠头计数徽章用（列表元素数）。
    var count: Int { hooks.count }

    private var rpc: JSONRPCClient?

    /// 注入 rpc + 拉初值（幂等：同一/新 rpc 都只是覆盖引用后重拉）。
    func attach(rpc: JSONRPCClient) async {
        self.rpc = rpc
        await refresh()
    }

    /// 拉取 hooks 列表（rpc 为 nil 时不发请求）。首版不传 cwds（空参 → daemon 用会话 cwd）。
    func refresh() async {
        guard let out: HooksListResponse =
            await send(RPCMethod.hooksList, params: EmptyParams(), as: HooksListResponse.self)
        else { return }
        hooks = Self.flatten(out)
    }

    /// 跨 cwd flatMap 打平 + 按 key 去重（防 SwiftUI List 重复 id 崩溃）。纯函数供单测（nonisolated 便于同步调用）。
    nonisolated static func flatten(_ response: HooksListResponse) -> [HookMetadata] {
        var seen = Set<String>()
        return response.data.flatMap { $0.hooks }.filter { seen.insert($0.key).inserted }
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
