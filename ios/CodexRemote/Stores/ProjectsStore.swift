import Foundation
import Observation

/// 一个「项目」= 同一 originUrl（或 cwd）下的 git 会话集合。左栏按项目分组展示。
struct Project: Identifiable {
    let id: String              // 归组键：originUrl ?? cwd
    let cwd: String
    let originUrl: String?
    var threads: [ThreadSummary]
    /// 显示名：origin 仓库名（去 .git）优先，否则 cwd 末段目录名。
    var displayName: String {
        if let o = originUrl, let repo = Self.repoName(o) { return repo }
        return (cwd as NSString).lastPathComponent
    }
    static func repoName(_ origin: String) -> String? {
        let trimmed = origin.hasSuffix(".git") ? String(origin.dropLast(4)) : origin
        let seg = trimmed.split(whereSeparator: { $0 == "/" || $0 == ":" }).last
        return seg.map(String.init)
    }
}

/// 状态层：拉取 `thread/list`，按 cwd 分组为项目，并维护「待批准」徽标集合。
@Observable
@MainActor
final class ProjectsStore {
    private(set) var projects: [Project] = []
    private(set) var looseConversations: [ThreadSummary] = []
    var isGrouped: Bool { projects.count >= 2 }
    var allThreadsSorted: [ThreadSummary] {
        (projects.flatMap(\.threads) + looseConversations).sorted { $0.updatedAt > $1.updatedAt }
    }
    private var pendingApproval: Set<String> = []

    /// session-management「桌面来源会话可见」：默认 sourceKinds 可能不含桌面 app（appServer）来源，
    /// 显式覆盖以确保桌面会话出现（设计 §13 Open Question，build 实测确认；不含也无害）。
    /// 真实 ThreadSourceKind 字符串值见 protocol/ts/v2/ThreadSourceKind.ts，桌面来源为 "appServer"。
    static func listParamsForDesktopVisibility() -> ThreadListParams {
        ThreadListParams(cursor: nil,
                         limit: 100,
                         sourceKinds: ["cli", "vscode", "exec", "appServer"],
                         cwd: nil,
                         searchTerm: nil,
                         archived: nil)
    }

    /// 从服务端拉取并 ingest。失败静默（保留旧 projects）。
    func loadFromServer(rpc: JSONRPCClient) async {
        let params = Self.listParamsForDesktopVisibility()
        guard let data = try? JSONEncoder().encode(params),
              let any = try? JSONDecoder().decode(AnyCodable.self, from: data),
              let result = try? await rpc.send(method: RPCMethod.threadList, params: any),
              let resData = try? JSONEncoder().encode(result),
              let resp = try? JSONDecoder().decode(ThreadListResponse.self, from: resData)
        else { return }
        ingest(resp.data)
    }

    /// 启发式分类（D8）：有 gitInfo → 项目（按 originUrl ?? cwd 归组）；否则 → 对话(loose)。
    /// 项目间按组内最近 updatedAt 倒序；项目内 / loose 按 updatedAt 倒序。
    func ingest(_ threads: [ThreadSummary]) {
        let projectThreads = threads.filter { $0.gitInfo != nil }
        let loose = threads.filter { $0.gitInfo == nil }
        let grouped = Dictionary(grouping: projectThreads) { t in
            (t.gitInfo?.originUrl?.isEmpty == false) ? t.gitInfo!.originUrl! : t.cwd
        }
        projects = grouped.map { key, ts in
            let sorted = ts.sorted { $0.updatedAt > $1.updatedAt }
            return Project(id: key, cwd: sorted.first?.cwd ?? key,
                           originUrl: sorted.first?.gitInfo?.originUrl, threads: sorted)
        }.sorted { ($0.threads.first?.updatedAt ?? 0) > ($1.threads.first?.updatedAt ?? 0) }
        looseConversations = loose.sorted { $0.updatedAt > $1.updatedAt }
    }

    func setPendingApproval(threadId: String, pending: Bool) {
        if pending { pendingApproval.insert(threadId) } else { pendingApproval.remove(threadId) }
    }

    func hasPendingApproval(_ threadId: String) -> Bool { pendingApproval.contains(threadId) }

    func pendingApprovalCount(in project: Project) -> Int {
        project.threads.filter { hasPendingApproval($0.id) }.count
    }
}
