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

enum ProjectsLoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed
}

/// 状态层：拉取 `thread/list`，按 cwd 分组为项目，并维护「待批准」徽标集合。
@Observable
@MainActor
final class ProjectsStore {
    private(set) var projects: [Project] = []
    private(set) var looseConversations: [ThreadSummary] = []
    private(set) var loadState: ProjectsLoadState = .idle
    var isGrouped: Bool { projects.count >= 2 }
    var allThreadsSorted: [ThreadSummary] {
        (projects.flatMap(\.threads) + looseConversations).sorted { $0.updatedAt > $1.updatedAt }
    }

    /// per-thread 运行态（来源：thread/list 初值 + thread/status/changed 广播）。批次②。
    private(set) var threadStatus: [String: ThreadStatus] = [:]

    // MARK: - 未读活动点（批次②，本地持久化）

    @ObservationIgnored private let unreadDefaults: UserDefaults
    private static let unreadKey = "ipad.sidebar.lastViewedAt.v1"
    /// per-thread 已读时间戳（threadId → lastViewedAt）。
    private var lastViewedAt: [String: Double] = [:]

    /// 注入 UserDefaults（默认 .standard）与时钟（默认 Date()）。
    /// 默认参数保证 `ProjectsStore()` 仍可用；`now` 注入供节流测试用假时钟。
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let pollSleep: @Sendable (UInt64) async -> Void
    init(unreadDefaults: UserDefaults = .standard,
         now: @escaping () -> Date = { Date() },
         pollSleep: @escaping @Sendable (UInt64) async -> Void = {
             try? await Task.sleep(nanoseconds: $0)
         }) {
        self.unreadDefaults = unreadDefaults
        self.now = now
        self.pollSleep = pollSleep
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
    /// D5-b：准实时轮询任务；nil = 未轮询。列表可见时启动、退后台/不可见时停止。
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var pollingRequested = false
    @ObservationIgnored private var pollBaseIntervalNanos: UInt64 = 30_000_000_000
    @ObservationIgnored private var pollMaxIntervalNanos: UInt64 = 300_000_000_000
    @ObservationIgnored private var fullSyncInProgress = false

    /// 启动周期轮询（D5-b）：列表可见时调用。幂等——已在轮询则忽略。
    /// 默认 30s；失败指数退避到 5min。每周期仅刷新首页，成本不随历史页数增长。
    /// 先 sleep 后 fetch，避免与首次 `.task` 的 loadFromServer 重复即时拉取。
    func startPolling(intervalNanos: UInt64 = 30_000_000_000,
                      maxIntervalNanos: UInt64 = 300_000_000_000,
                      isVisible: Bool = true) {
        guard isVisible else { return }
        pollingRequested = true
        pollBaseIntervalNanos = intervalNanos
        pollMaxIntervalNanos = max(maxIntervalNanos, intervalNanos)
        restartPollingIfNeeded()
    }

    private func restartPollingIfNeeded() {
        guard pollingRequested, pollTask == nil, rpc != nil else { return }
        let base = pollBaseIntervalNanos
        let maximum = pollMaxIntervalNanos
        pollTask = Task { [weak self] in
            var delay = base
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollSleep(delay)
                guard !Task.isCancelled, self.pollingRequested, let rpc = self.rpc else { return }
                let succeeded = await self.refreshRecentPage(rpc: rpc)
                guard !Task.isCancelled, self.rpc === rpc else { return }
                if succeeded {
                    delay = base
                } else {
                    delay = delay >= maximum / 2 ? maximum : min(delay * 2, maximum)
                }
            }
        }
    }

    /// 停止周期轮询（列表不可见/退后台）。
    func stopPolling() {
        pollingRequested = false
        pollTask?.cancel()
        pollTask = nil
    }

    /// 立即刷新一次（回前台/列表获焦时调用）。
    func refreshNow() async {
        if let rpc { _ = await refreshRecentPage(rpc: rpc) }
    }

    /// 注入 rpc 并启动官方广播监听（设计 D3：多端一致靠广播，不自建同步）。幂等；
    /// 完整重连换新 rpc 实例时取消旧订阅并对新 rpc 重订阅（否则 guard==nil 挡住重订阅 →
    /// 重连后新连接的官方广播永不刷新列表，UI 停在断线前快照）。
    func attach(rpc: JSONRPCClient) async {
        let rpcChanged = self.rpc !== rpc
        self.rpc = rpc
        if rpcChanged {
            broadcastObserver?.cancel()
            broadcastObserver = nil
            pollTask?.cancel()
            pollTask = nil
        }
        if broadcastObserver == nil {
            let stream = await rpc.notifications(methods: ServerNotificationMethod.projectMethods)
            broadcastObserver = Task { [weak self] in
                for await n in stream {
                    await MainActor.run { self?.applyBroadcast(n) }
                }
            }
        }
        if rpcChanged { restartPollingIfNeeded() }
    }

    /// 官方广播 → 本地列表更新（删除/归档移除，改名就地改，取消归档重拉）。
    private func applyBroadcast(_ n: JSONRPCNotification) {
        guard let p = n.params?.value as? [String: Any] else { return }
        if n.method == ServerNotificationMethod.threadStarted {
            Task { await self.handleThreadStarted(n) }
            return
        }
        guard let tid = p["threadId"] as? String else { return }
        switch n.method {
        case ServerNotificationMethod.threadDeleted,
             ServerNotificationMethod.threadArchived:
            removeThread(tid)
        case ServerNotificationMethod.threadNameUpdated:
            let newName = p["threadName"] as? String
            renameLocal(tid, to: newName)
        case ServerNotificationMethod.threadUnarchived:
            Task { if let rpc = self.rpc { _ = await self.refreshRecentPage(rpc: rpc) } }
        case ServerNotificationMethod.threadStatusChanged:
            // 用 ThreadStatusChangedNotification 整体解码（去重 params 二次解析）。
            if let data = try? JSONSerialization.data(withJSONObject: p),
               let note = try? JSONDecoder().decode(ThreadStatusChangedNotification.self, from: data) {
                handleStatusChanged(threadId: note.threadId, status: note.status)
            }
        default:
            break
        }
    }

    /// 消费 thread/started 广播（D5-a）。已存在按 id 去重直接返回；
    /// 未知 id → 重拉 thread/list 一次，由既有 ingest 归一化（广播 payload 字段不足以
    /// 构造完整 ThreadSummary，ingest 依赖 gitInfo/status 分类，故不手拼摘要）。
    func handleThreadStarted(_ n: JSONRPCNotification) async {
        guard let p = n.params?.value as? [String: Any],
              let thread = p["thread"] as? [String: Any],
              let tid = thread["id"] as? String else { return }
        if allThreadsSorted.contains(where: { $0.id == tid }) { return }   // 去重
        if let rpc { _ = await refreshRecentPage(rpc: rpc) }               // 最近页重拉让 ingest 归一化
    }

    private func removeThread(_ id: String) {
        for i in projects.indices { projects[i].threads.removeAll { $0.id == id } }
        projects.removeAll { $0.threads.isEmpty }
        looseConversations.removeAll { $0.id == id }
        // 批次②：清理该 thread 的运行态与已读记录，避免 map 无界增长。
        threadStatus.removeValue(forKey: id)
        if lastViewedAt.removeValue(forKey: id) != nil {
            unreadDefaults.set(lastViewedAt, forKey: Self.unreadKey)
        }
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

    /// 新建会话进行中标志（防抖）：createThread 期间为 true，禁止并发重复新建。
    private(set) var isCreatingThread = false
    private(set) var createThreadError: String?
    /// 上次成功发起新建的时间（节流）：窗内再次新建被拒，治本机往返极快、串行快速连点建多个空会话。
    @ObservationIgnored private var lastCreateAt: Date?
    private static let createThrottleInterval: TimeInterval = 2.0

    /// 新建会话：发 `thread/start`，解析响应 `{thread:{id}}` 返回新 thread id（失败 nil）。
    /// 供顶栏新建按钮调用——View 拿到新 id 后切 `selectedThreadId` 进入新会话。
    /// rpc 显式传入（对齐 `loadFromServer(rpc:)`；`projects` 实例的 `self.rpc` 从未经 attach 注入，
    /// 见 design D1 深挖——attach 未接线是 Task 4/5 同步层的既有问题，此处不依赖 self.rpc）。
    func createThread(rpc: JSONRPCClient, cwd: String? = nil, model: String? = nil) async -> String? {
        guard !isCreatingThread else { return nil }   // 防抖：创建进行中拒绝并发重复新建
        let t = now()
        if let last = lastCreateAt, t.timeIntervalSince(last) < Self.createThrottleInterval {
            return nil                                // 节流：1s 内的连续新建被拒
        }
        lastCreateAt = t
        createThreadError = nil
        isCreatingThread = true
        defer { isCreatingThread = false }
        do {
            let data = try JSONEncoder().encode(ThreadStartParams(cwd: cwd, model: model))
            let any = try JSONDecoder().decode(AnyCodable.self, from: data)
            let result = try await rpc.send(method: RPCMethod.threadStart, params: any)
            guard let dict = result.value as? [String: Any],
                  let id = (dict["thread"] as? [String: Any])?["id"] as? String else {
                createThreadError = L10n.string(
                    "operation.failed.description", locale: LocaleManager.currentLocale
                )
                return nil
            }
            return id
        } catch {
            createThreadError = L10n.string(
                "operation.failed.description", locale: LocaleManager.currentLocale
            )
            return nil
        }
    }

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

    /// 单页翻页硬上限（#7 能耗红线）：防御 daemon 返回环状/错误 nextCursor 导致无限循环。
    /// 50 页 * limit 100 = 5000 条会话，远超常规上限；达到即停并保留已拉取的页。
    private static let maxListPages = 50

    /// 从服务端拉取并 ingest。跟随 `nextCursor` 翻页直到 nil 或触达硬上限（#7：不能只读首页，
    /// 否则会话数超单页时重连恢复丢会话）。首页请求失败：静默失败保留旧 projects（既有语义）；
    /// 后续页失败：停止翻页，用已累积的页 ingest（不因某一页失败丢弃已成功拉到的页）。
    func loadFromServer(rpc: JSONRPCClient) async {
        guard !fullSyncInProgress else { return }
        fullSyncInProgress = true
        if allThreadsSorted.isEmpty { loadState = .loading }
        defer { fullSyncInProgress = false }
        var cursor: String?
        var accumulated: [ThreadSummary] = []
        for pageIndex in 0..<Self.maxListPages {
            var params = Self.listParamsForDesktopVisibility()
            params.cursor = cursor
            guard let data = try? JSONEncoder().encode(params),
                  let any = try? JSONDecoder().decode(AnyCodable.self, from: data),
                  let result = try? await rpc.send(method: RPCMethod.threadList, params: any),
                  let resData = try? JSONEncoder().encode(result),
                  let resp = try? JSONDecoder().decode(ThreadListResponse.self, from: resData)
            else {
                if pageIndex == 0 {
                    if allThreadsSorted.isEmpty { loadState = .failed }
                    return
                }
                break                          // 后续页失败：用已累积的页 ingest
            }
            accumulated.append(contentsOf: resp.data)
            guard let next = resp.nextCursor else { break }
            cursor = next
        }
        if let current = self.rpc, current !== rpc { return }
        ingest(accumulated)
        loadState = .loaded
    }

    /// 常态刷新只取首页并与本地历史按 id 合并；删除/归档由官方广播精确移除。
    @discardableResult
    func refreshRecentPage(rpc: JSONRPCClient) async -> Bool {
        let params = Self.listParamsForDesktopVisibility()
        guard let data = try? JSONEncoder().encode(params),
              let any = try? JSONDecoder().decode(AnyCodable.self, from: data),
              let result = try? await rpc.send(method: RPCMethod.threadList, params: any),
              let resData = try? JSONEncoder().encode(result),
              let response = try? JSONDecoder().decode(ThreadListResponse.self, from: resData)
        else { return false }
        if let current = self.rpc, current !== rpc { return false }

        var merged: [String: ThreadSummary] = [:]
        for thread in allThreadsSorted + response.data {
            if let existing = merged[thread.id], existing.updatedAt > thread.updatedAt { continue }
            merged[thread.id] = thread
        }
        ingest(Array(merged.values))
        return true
    }

    /// 启发式分类（D8）：有 gitInfo → 项目（按 originUrl ?? cwd 归组）；否则 → 对话(loose)。
    /// 项目间按组内最近 updatedAt 倒序；项目内 / loose 按 updatedAt 倒序。
    func ingest(_ threads: [ThreadSummary]) {
        var threadsByID: [String: ThreadSummary] = [:]
        for thread in threads {
            if let existing = threadsByID[thread.id], existing.updatedAt > thread.updatedAt { continue }
            threadsByID[thread.id] = thread
        }
        let uniqueThreads = Array(threadsByID.values)
        let projectThreads = uniqueThreads.filter { $0.gitInfo != nil }
        let loose = uniqueThreads.filter { $0.gitInfo == nil }
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
        // 假设 thread/list 返回的是最新态（daemon 侧 list 与 broadcast 无显式时序号，
        // 重拉以 list 为准）；仅在 status 非 nil 时覆盖，避免把已知态降级为 nil。
        for t in threads where t.status != nil { threadStatus[t.id] = t.status }
    }

    func pendingApprovalCount(in project: Project) -> Int {
        project.threads.filter {
            if case .active(let flags) = threadStatus[$0.id], flags.contains(.waitingOnApproval) { return true }
            return false
        }.count
    }
}
