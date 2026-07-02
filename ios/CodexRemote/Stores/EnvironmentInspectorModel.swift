import Foundation
import Observation

/// 环境 inspector 的按需拉取层（批次⑤）：全量 git diff 总数 + GitHub 认证。
/// 子智能体走 ThreadReducer（ConversationState.subAgents），不在此。
@Observable
@MainActor
final class EnvironmentInspectorModel {
    private(set) var diffStats: TurnDiffStats.Stats?
    private(set) var diffSha: String?
    private(set) var authStatus: GetAuthStatusResponse?

    private var rpc: JSONRPCClient?
    func attach(rpc: JSONRPCClient) { self.rpc = rpc }

    static func diffParams(cwd: String) -> GitDiffToRemoteParams { GitDiffToRemoteParams(cwd: cwd) }
    static func stats(fromDiff diff: String) -> TurnDiffStats.Stats { TurnDiffStats.parse(diff) }

    /// inspector 打开/会话切换时拉取（cwd 取当前会话）。
    func refresh(cwd: String?) async {
        // 清场：避免切换会话时上一会话的 auth/diff 残留串场（I1）。
        authStatus = nil; diffStats = nil; diffSha = nil
        await fetchAuth()
        guard let cwd, !cwd.isEmpty else { return }
        await fetchDiff(cwd: cwd)
    }

    private func fetchDiff(cwd: String) async {
        guard let rpc,
              let d = try? JSONEncoder().encode(Self.diffParams(cwd: cwd)),
              let any = try? JSONDecoder().decode(AnyCodable.self, from: d),
              let res = try? await rpc.send(method: RPCMethod.gitDiffToRemote, params: any),
              let rd = try? JSONEncoder().encode(res),
              let out = try? JSONDecoder().decode(GitDiffToRemoteResponse.self, from: rd) else { return }
        diffSha = out.sha
        diffStats = Self.stats(fromDiff: out.diff)
    }
    private func fetchAuth() async {
        guard let rpc,
              let empty = try? JSONDecoder().decode(AnyCodable.self, from: Data("{}".utf8)),
              let res = try? await rpc.send(method: RPCMethod.getAuthStatus, params: empty),
              let rd = try? JSONEncoder().encode(res),
              let out = try? JSONDecoder().decode(GetAuthStatusResponse.self, from: rd) else { return }
        authStatus = out
    }
}
