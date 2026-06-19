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
    /// sidebar-status-badges：每会话实时态映射（设计 D3）。断线不清空（B7）。
    private var liveStatus: [String: LiveStatus] = [:]
    /// 当前选中的会话 id（设计 B4：选中会话恒为已读）。由 SidebarView 接线。
    private(set) var selectedThreadId: String?
    /// 未读追踪（设计 D4）。构造注入；默认 .standard 供生产用。
    private let readState: ReadStateStore

    init(readState: ReadStateStore = ReadStateStore()) {
        self.readState = readState
    }

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
        // 回填实时态（设计 D3 兜底；B5：未推送的会话靠 thread/list status 字段）。
        for t in threads {
            liveStatus[t.id] = LiveStatus.from(threadStatus: t.statusType, activeFlags: t.activeFlags)
        }
        // B4：选中会话每次刷新都重锚到新 updatedAt（在看期间不积累未读；离开后以最后所见为锚）。
        if let sel = selectedThreadId, let t = threads.first(where: { $0.id == sel }) {
            readState.markViewed(sel, updatedAt: t.updatedAt)
        }
    }

    func setPendingApproval(threadId: String, pending: Bool) {
        if pending { pendingApproval.insert(threadId) } else { pendingApproval.remove(threadId) }
    }

    func hasPendingApproval(_ threadId: String) -> Bool { pendingApproval.contains(threadId) }

    func pendingApprovalCount(in project: Project) -> Int {
        project.threads.filter { hasPendingApproval($0.id) }.count
    }

    // MARK: - sidebar-status-badges

    /// StatusCoordinator 写入实时态（设计 D3）。
    func setLiveStatus(_ threadId: String, _ status: LiveStatus) {
        liveStatus[threadId] = status
    }

    /// turn/completed 时持久化结局（设计 D4，B8）。
    func recordOutcome(_ threadId: String, outcome: Outcome) {
        readState.recordOutcome(threadId, outcome: outcome)
    }

    /// 点击选中会话 → 标记已读到该会话当前 updatedAt（设计 D4，B3/B4）。
    func markViewed(_ threadId: String) {
        guard let t = threadById(threadId) else { return }
        readState.markViewed(threadId, updatedAt: t.updatedAt)
    }

    /// 设置当前选中会话（设计 B4：选中会话恒为已读）。SidebarView 接线。
    func setSelected(_ id: String?) {
        selectedThreadId = id
    }

    /// 组合实时态 + 未读态，仲裁单一徽标（设计 D2/D4）。
    func badge(_ threadId: String) -> ThreadBadge {
        guard let t = threadById(threadId) else { return .none }
        // M2：单一真相源——待批准期间 live 强制 .waiting（防完成事件清 live 致蓝点闪烁）。
        let live: LiveStatus = hasPendingApproval(threadId) ? .waiting : (liveStatus[threadId] ?? .none)
        // B4：选中会话恒为已读——viewedAt 视为 .infinity（updatedAt > ∞ 恒 false → 永不未读）。
        let viewedAt = (threadId == selectedThreadId) ? .infinity : readState.viewedAt(threadId)
        return ThreadBadge.resolve(
            live: live,
            outcome: readState.lastOutcome(threadId),
            updatedAt: t.updatedAt,
            viewedAt: viewedAt)
    }

    private func threadById(_ id: String) -> ThreadSummary? {
        if let t = projects.flatMap(\.threads).first(where: { $0.id == id }) { return t }
        return looseConversations.first(where: { $0.id == id })
    }
}
