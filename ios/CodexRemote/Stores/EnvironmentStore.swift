import Foundation
import Observation

/// 环境信息状态层（批次④）：账户/用量/速率（只读）+ 模型 + curated 配置（读写）。
/// 与 ProjectsStore 并列；复用 ① 传输的 rpc + notifications 管线。
@Observable
@MainActor
final class EnvironmentStore {
    private(set) var account: Account?
    private(set) var requiresOpenaiAuth = false
    private(set) var usage: AccountTokenUsageSummary?
    private(set) var rateLimits: RateLimitSnapshot?
    private(set) var config: CuratedConfig?
    private(set) var models: [ModelSummary] = []    // model/list 结果（过滤隐藏）

    private var rpc: JSONRPCClient?
    private var observer: Task<Void, Never>?

    /// 注入 rpc：拉初值 + 订阅账户广播。幂等。
    func attach(rpc: JSONRPCClient) async {
        self.rpc = rpc
        await refreshAll()
        guard observer == nil else { return }
        let stream = await rpc.notifications()
        observer = Task { [weak self] in
            for await n in stream { await MainActor.run { self?.applyBroadcast(n) } }
        }
    }

    func refreshAll() async {
        await fetchAccount(); await fetchUsage(); await fetchRateLimits(); await fetchConfig(); await fetchModels()
    }

    // MARK: 广播（internal 供单测）
    func handleAccountUpdated(_ a: Account?) { account = a }
    func handleRateLimitsUpdated(_ s: RateLimitSnapshot) { rateLimits = s }

    private func applyBroadcast(_ n: JSONRPCNotification) {
        switch n.method {
        case ServerNotificationMethod.accountUpdated:
            // account/updated payload 为 sparse {authMode, planType}，不含完整 Account；
            // 收到即重拉 account/read（最稳，规避 sparse 合并）。
            Task { await fetchAccount() }
        case ServerNotificationMethod.accountRateLimitsUpdated:
            if let s = Self.decodeNested(n, key: "rateLimits", as: RateLimitSnapshot.self) { handleRateLimitsUpdated(s) }
        default: break
        }
    }

    // MARK: 写参数（static 纯函数，便于单测）
    static func modelWriteParams(modelId: String) -> ConfigValueWriteParams {
        ConfigValueWriteParams(keyPath: "model", value: AnyCodable(modelId), mergeStrategy: "replace")
    }
    static func configWriteParams(keyPath: String, stringValue: String) -> ConfigValueWriteParams {
        ConfigValueWriteParams(keyPath: keyPath, value: AnyCodable(stringValue), mergeStrategy: "replace")
    }

    func switchModel(_ id: String) async { await write(Self.modelWriteParams(modelId: id)) }
    func writeConfig(keyPath: String, stringValue: String) async {
        await write(Self.configWriteParams(keyPath: keyPath, stringValue: stringValue))
    }

    // MARK: 私有拉取/写入
    private func sendDecode<T: Decodable>(_ method: String, as: T.Type) async -> T? {
        guard let rpc else { return nil }
        let empty = (try? JSONDecoder().decode(AnyCodable.self, from: Data("{}".utf8)))
        guard let res = try? await rpc.send(method: method, params: empty),
              let rd = try? JSONEncoder().encode(res),
              let out = try? JSONDecoder().decode(T.self, from: rd) else { return nil }
        return out
    }
    private func fetchAccount() async {
        if let r: GetAccountResponse = await sendDecode(RPCMethod.accountRead, as: GetAccountResponse.self) {
            account = r.account; requiresOpenaiAuth = r.requiresOpenaiAuth
        }
    }
    private func fetchUsage() async {
        if let r: GetAccountTokenUsageResponse = await sendDecode(RPCMethod.accountUsageRead, as: GetAccountTokenUsageResponse.self) { usage = r.summary }
    }
    private func fetchRateLimits() async {
        if let r: GetAccountRateLimitsResponse = await sendDecode(RPCMethod.accountRateLimitsRead, as: GetAccountRateLimitsResponse.self) { rateLimits = r.rateLimits }
    }
    private func fetchConfig() async {
        if let r: ConfigReadResponse = await sendDecode(RPCMethod.configRead, as: ConfigReadResponse.self) { config = r.config }
    }
    private func fetchModels() async {
        if let r: ModelListResponse = await sendDecode(RPCMethod.modelList, as: ModelListResponse.self) {
            models = r.data.filter { !$0.hidden }   // 隐藏模型过滤
        }
    }

    private func write(_ p: ConfigValueWriteParams) async {
        guard let rpc, let d = try? JSONEncoder().encode(p), let any = try? JSONDecoder().decode(AnyCodable.self, from: d) else { return }
        _ = try? await rpc.send(method: RPCMethod.configValueWrite, params: any)
        await fetchConfig()   // 写后重读确认
    }

    private static func decodeNested<T: Decodable>(_ n: JSONRPCNotification, key: String, as: T.Type) -> T? {
        guard let p = n.params?.value as? [String: Any], let sub = p[key],
              let d = try? JSONSerialization.data(withJSONObject: sub),
              let out = try? JSONDecoder().decode(T.self, from: d) else { return nil }
        return out
    }
}
