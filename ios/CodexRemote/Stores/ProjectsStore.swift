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

/// 侧栏运行态徽标种类（批次②，纯派生自 ThreadStatus）。
enum RunStateBadge: Equatable {
    case none
    case running         // active 无 flag → spinner
    case waitingInput    // waitingOnUserInput
    case waitingApproval // waitingOnApproval（与 input 并存时优先）
    case error           // systemError

    static func from(_ status: ThreadStatus?) -> RunStateBadge {
        switch status {
        case .active(let flags):
            if flags.contains(.waitingOnApproval) { return .waitingApproval }
            if flags.contains(.waitingOnUserInput) { return .waitingInput }
            return .running
        case .systemError: return .error
        case .idle, .notLoaded, nil: return RunStateBadge.none
        }
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

    /// per-thread 运行态（来源：thread/list 初值 + thread/status/changed 广播）。批次②。
    private(set) var threadStatus: [String: ThreadStatus] = [:]

    // MARK: - 未读活动点（批次②，本地持久化）

    @ObservationIgnored private let unreadDefaults: UserDefaults
    private static let unreadKey = "ipad.sidebar.lastViewedAt.v1"
    /// per-thread 已读时间戳（threadId → lastViewedAt）。
    private var lastViewedAt: [String: Double] = [:]

    /// 注入 UserDefaults（默认 .standard），加载持久化的已读时间戳。
    /// 默认参数保证 `ProjectsStore()` 仍可用。
    init(unreadDefaults: UserDefaults = .standard) {
        self.unreadDefaults = unreadDefaults
        self.lastViewedAt = (unreadDefaults.dictionary(forKey: Self.unreadKey) as? [String: Double]) ?? [:]
    }

    /// 未读判定：当前选中不亮（前置）；否则 updatedAt > lastViewedAt。
    func hasUnread(_ thread: ThreadSummary, isSelected: Bool) -> Bool {
        if isSelected { return false }
        return thread.updatedAt > (lastViewedAt[thread.id] ?? 0)
    }

    /// 进入会话：更新已读时间戳并持久化。
    func markViewed(threadId: String, updatedAt: Double) {
        lastViewedAt[threadId] = updatedAt
        unreadDefaults.set(lastViewedAt, forKey: Self.unreadKey)
    }

    func status(of threadId: String) -> ThreadStatus? { threadStatus[threadId] }

    /// 消费 thread/status/changed（internal 供单测）。
    func handleStatusChanged(threadId: String, status: ThreadStatus) {
        threadStatus[threadId] = status
    }

    private var rpc: JSONRPCClient?
    private var broadcastObserver: Task<Void, Never>?

    /// 注入 rpc 并启动官方广播监听（设计 D3：多端一致靠广播，不自建同步）。幂等。
    func attach(rpc: JSONRPCClient) async {
        self.rpc = rpc
        guard broadcastObserver == nil else { return }
        let stream = await rpc.notifications()
        broadcastObserver = Task { [weak self] in
            for await n in stream {
                await MainActor.run { self?.applyBroadcast(n) }
            }
        }
    }

    /// 官方广播 → 本地列表更新（删除/归档移除，改名就地改，取消归档重拉）。
    private func applyBroadcast(_ n: JSONRPCNotification) {
        guard let p = n.params?.value as? [String: Any],
              let tid = p["threadId"] as? String else { return }
        switch n.method {
        case ServerNotificationMethod.threadDeleted,
             ServerNotificationMethod.threadArchived:
            removeThread(tid)
        case ServerNotificationMethod.threadNameUpdated:
            let newName = p["threadName"] as? String
            renameLocal(tid, to: newName)
        case ServerNotificationMethod.threadUnarchived:
            Task { if let rpc = self.rpc { await self.loadFromServer(rpc: rpc) } }
        case ServerNotificationMethod.threadStatusChanged:
            if let dict = p["status"],
               let data = try? JSONSerialization.data(withJSONObject: dict),
               let st = try? JSONDecoder().decode(ThreadStatus.self, from: data) {
                handleStatusChanged(threadId: tid, status: st)
            }
        default:
            break
        }
    }

    private func removeThread(_ id: String) {
        for i in projects.indices { projects[i].threads.removeAll { $0.id == id } }
        projects.removeAll { $0.threads.isEmpty }
        looseConversations.removeAll { $0.id == id }
    }

    private func renameLocal(_ id: String, to name: String?) {
        for i in projects.indices {
            for j in projects[i].threads.indices where projects[i].threads[j].id == id {
                projects[i].threads[j].name = name
            }
        }
        for j in looseConversations.indices where looseConversations[j].id == id {
            looseConversations[j].name = name
        }
    }

    // MARK: - 管理动作（成功后重拉列表；广播会再叠加）

    private func sendThenRefresh<T: Encodable>(_ method: String, _ params: T) async {
        guard let rpc else { return }
        guard let data = try? JSONEncoder().encode(params),
              let any = try? JSONDecoder().decode(AnyCodable.self, from: data) else { return }
        _ = try? await rpc.send(method: method, params: any)
        await loadFromServer(rpc: rpc)
    }

    func archive(threadId: String) async {
        await sendThenRefresh(RPCMethod.threadArchive, ThreadArchiveParams(threadId: threadId))
    }
    func unarchive(threadId: String) async {
        await sendThenRefresh(RPCMethod.threadUnarchive, ThreadUnarchiveParams(threadId: threadId))
    }
    func delete(threadId: String) async {
        await sendThenRefresh(RPCMethod.threadDelete, ThreadDeleteParams(threadId: threadId))
    }
    func rename(threadId: String, name: String) async {
        await sendThenRefresh(RPCMethod.threadNameSet, ThreadSetNameParams(threadId: threadId, name: name))
    }
    func rollback(threadId: String, numTurns: Int) async {
        await sendThenRefresh(RPCMethod.threadRollback,
                              ThreadRollbackParams(threadId: threadId, numTurns: max(1, numTurns)))
    }
    func compact(threadId: String) async {
        await sendThenRefresh(RPCMethod.threadCompactStart, ThreadCompactStartParams(threadId: threadId))
    }
    func setGoal(threadId: String, objective: String?, status: ThreadGoalStatus?) async {
        await sendThenRefresh(RPCMethod.threadGoalSet,
                              ThreadGoalSetParams(threadId: threadId, objective: objective, status: status, tokenBudget: nil))
    }
    func clearGoal(threadId: String) async {
        await sendThenRefresh(RPCMethod.threadGoalClear, ThreadGoalClearParams(threadId: threadId))
    }
    /// 查目标：返回当前 goal（nil = 未设）。供 UI 打开 goal 编辑面板时预填。
    func fetchGoal(threadId: String) async -> ThreadGoal? {
        guard let rpc else { return nil }
        guard let data = try? JSONEncoder().encode(ThreadGoalGetParams(threadId: threadId)),
              let any = try? JSONDecoder().decode(AnyCodable.self, from: data),
              let res = try? await rpc.send(method: RPCMethod.threadGoalGet, params: any),
              let resData = try? JSONEncoder().encode(res),
              let resp = try? JSONDecoder().decode(ThreadGoalGetResponse.self, from: resData)
        else { return nil }
        return resp.goal
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
        // 运行态初值（批次②）：thread/list 项携带 status。
        for t in threads where t.status != nil { threadStatus[t.id] = t.status }
    }

    func setPendingApproval(threadId: String, pending: Bool) {
        if pending { pendingApproval.insert(threadId) } else { pendingApproval.remove(threadId) }
    }

    func hasPendingApproval(_ threadId: String) -> Bool { pendingApproval.contains(threadId) }

    func pendingApprovalCount(in project: Project) -> Int {
        project.threads.filter { hasPendingApproval($0.id) }.count
    }
}
