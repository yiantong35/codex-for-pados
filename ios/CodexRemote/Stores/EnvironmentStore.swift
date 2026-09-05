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
    private var attachmentGeneration = 0
    private var accountRefreshGeneration = 0

    /// 注入 rpc：拉初值 + 订阅账户广播。幂等；完整重连换新 rpc 实例时取消旧订阅并对新 rpc
    /// 重订阅（否则 guard observer==nil 挡住重订阅 → 新连接的 account/rateLimits 广播永不刷新）。
    func attach(rpc: JSONRPCClient) async {
        let rpcChanged = self.rpc !== rpc
        if !rpcChanged, observer != nil { await refreshAll(); return }
        attachmentGeneration &+= 1
        let generation = attachmentGeneration
        self.rpc = rpc
        if rpcChanged { observer?.cancel(); observer = nil }
        let stream = await rpc.notifications(methods: ServerNotificationMethod.environmentMethods)
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
        await refreshAll(using: rpc, generation: generation)
    }

    func refreshAll() async {
        guard let rpc else { return }
        await refreshAll(using: rpc, generation: attachmentGeneration)
    }

    private func refreshAll(using rpc: JSONRPCClient, generation: Int) async {
        await fetchAccount(using: rpc, generation: generation)
        // 仅 ChatGPT 账号登录才有用量/限额；apikey / amazonBedrock 无（account/usage/read、
        // account/rateLimits/read 会回 -32600 "chatgpt authentication required"，无意义）。
        // 用 account 类型门控，避免对无用量账号发起这两次请求，也不误显示空用量卡片。
        if Self.shouldReadUsage(account: account) {
            await fetchUsage(using: rpc, generation: generation)
            await fetchRateLimits(using: rpc, generation: generation)
        } else {
            usage = nil
            rateLimits = nil
        }
        await fetchConfig(using: rpc, generation: generation)
        await fetchModels(using: rpc, generation: generation)
    }

    /// 仅 ChatGPT 账号登录才有用量/限额（apikey / amazonBedrock 无 → 读会回 -32600
    /// "chatgpt authentication required"，无意义）。抽成 nonisolated 纯函数便于单测。
    static nonisolated func shouldReadUsage(account: Account?) -> Bool {
        if case .chatgpt = account { return true }
        return false
    }

    // MARK: 广播（internal 供单测）
    func handleAccountUpdated(_ a: Account?) { account = a }
    func handleRateLimitsUpdated(_ s: RateLimitSnapshot) { rateLimits = s }

    private func applyBroadcast(_ n: JSONRPCNotification) {
        switch n.method {
        case ServerNotificationMethod.accountUpdated:
            // account/updated payload 为 sparse {authMode, planType}，不含完整 Account；
            // 收到即重拉 account/read（最稳，规避 sparse 合并）。
            Task { await refreshAccount() }
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
    private func sendDecode<T: Decodable>(rpc: JSONRPCClient, _ method: String, as: T.Type) async -> T? {
        let empty = (try? JSONDecoder().decode(AnyCodable.self, from: Data("{}".utf8)))
        guard let res = try? await rpc.send(method: method, params: empty),
              let rd = try? JSONEncoder().encode(res),
              let out = try? JSONDecoder().decode(T.self, from: rd) else { return nil }
        return out
    }
    private func refreshAccount() async {
        guard let rpc else { return }
        await fetchAccount(using: rpc, generation: attachmentGeneration)
    }
    private func fetchAccount(using rpc: JSONRPCClient, generation: Int) async {
        accountRefreshGeneration &+= 1
        let refresh = accountRefreshGeneration
        if let r: GetAccountResponse = await sendDecode(rpc: rpc, RPCMethod.accountRead, as: GetAccountResponse.self),
           generation == attachmentGeneration, refresh == accountRefreshGeneration, self.rpc === rpc {
            account = r.account; requiresOpenaiAuth = r.requiresOpenaiAuth
        }
    }
    private func fetchUsage(using rpc: JSONRPCClient, generation: Int) async {
        if let r: GetAccountTokenUsageResponse = await sendDecode(rpc: rpc, RPCMethod.accountUsageRead, as: GetAccountTokenUsageResponse.self),
           generation == attachmentGeneration, self.rpc === rpc { usage = r.summary }
    }
    private func fetchRateLimits(using rpc: JSONRPCClient, generation: Int) async {
        if let r: GetAccountRateLimitsResponse = await sendDecode(rpc: rpc, RPCMethod.accountRateLimitsRead, as: GetAccountRateLimitsResponse.self),
           generation == attachmentGeneration, self.rpc === rpc { rateLimits = r.rateLimits }
    }
    private func fetchConfig(using rpc: JSONRPCClient, generation: Int) async {
        if let r: ConfigReadResponse = await sendDecode(rpc: rpc, RPCMethod.configRead, as: ConfigReadResponse.self),
           generation == attachmentGeneration, self.rpc === rpc { config = r.config }
    }
    private func fetchModels(using rpc: JSONRPCClient, generation: Int) async {
        if let r: ModelListResponse = await sendDecode(rpc: rpc, RPCMethod.modelList, as: ModelListResponse.self),
           generation == attachmentGeneration, self.rpc === rpc {
            models = r.data.filter { !$0.hidden }   // 隐藏模型过滤
        }
    }

    private func write(_ p: ConfigValueWriteParams) async {
        guard let rpc, let d = try? JSONEncoder().encode(p), let any = try? JSONDecoder().decode(AnyCodable.self, from: d) else { return }
        _ = try? await rpc.send(method: RPCMethod.configValueWrite, params: any)
        await fetchConfig(using: rpc, generation: attachmentGeneration)   // 写后重读确认
    }

    private static func decodeNested<T: Decodable>(_ n: JSONRPCNotification, key: String, as: T.Type) -> T? {
        guard let p = n.params?.value as? [String: Any], let sub = p[key],
              let d = try? JSONSerialization.data(withJSONObject: sub),
              let out = try? JSONDecoder().decode(T.self, from: d) else { return nil }
        return out
    }
}
