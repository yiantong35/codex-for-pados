import Foundation

enum ReasoningEffort: String, Codable {
    case none, minimal, low, medium, high, xhigh
}

// 取自 v2/Thread.ts 子集。真实 thread/list 返回的 Thread 含大量嵌套字段
// (status/source/threadSource/gitInfo/turns 等)；MVP 仅建模渲染所需字段，
// 其余字段由 Swift Codable 默认忽略多余 JSON key 的行为容错跳过。
/// 取自 v2/GitInfo.ts（sha/branch/originUrl）。MVP 仅取分类/展示所需 originUrl/branch。
struct GitInfoSummary: Codable, Equatable {
    var sha: String?
    var branch: String?
    var originUrl: String?
}

struct ThreadSummary: Codable, Identifiable {
    let id: String
    let sessionId: String
    let preview: String
    let modelProvider: String
    let createdAt: Double                           // Unix 秒
    let updatedAt: Double                           // Unix 秒
    let cwd: String                                 // AbsolutePathBuf -> String
    let cliVersion: String
    var name: String?
    var gitInfo: GitInfoSummary?                    // null 表示非 git 仓库（分类信号，见 D8）
}

struct ThreadListParams: Codable {
    var cursor: String?
    var limit: Int?
    // ThreadSourceKind: "cli"|"vscode"|"exec"|"appServer"|"subAgent"|...
    // 设计 §13 Open Question：默认 sourceKinds 是否含桌面 app(appServer)来源。
    // 为确保桌面会话可见，显式传入覆盖项(见 session-management 场景「桌面来源会话可见」)。
    var sourceKinds: [String]?
    // 真实 cwd 类型为 string | Array<string> | null；MVP 仅支持 [String]?。
    var cwd: [String]?
    var searchTerm: String?
    var archived: Bool?
}

struct ThreadListResponse: Codable {
    let data: [ThreadSummary]
    let nextCursor: String?
    let backwardsCursor: String?
}

struct ThreadResumeParams: Codable {
    let threadId: String
    var model: String?
    var cwd: String?
}

/// 空参数（编码为 `{}`）：用于 `thread/loaded/list` 等无参方法。
struct EmptyParams: Encodable {}

/// `thread/loaded/list` 响应：data 为当前 app-server 内存中运行/已加载的 thread id 数组，
/// nextCursor 用于翻页（首页通常已覆盖全部活跃 thread）。字段名以 spike 实测坐实（spike-findings §4）。
struct LoadedThreadList: Decodable {
    let data: [String]
    let nextCursor: String?
}

struct ThreadStartParams: Codable {
    var cwd: String?
    var model: String?
}

// MARK: - 会话管理（ipad-follower-session-control，protocol v2）

struct ThreadArchiveParams: Codable { let threadId: String }
struct ThreadUnarchiveParams: Codable { let threadId: String }
struct ThreadDeleteParams: Codable { let threadId: String }
struct ThreadCompactStartParams: Codable { let threadId: String }

/// schema 类型名 ThreadSetNameParams，参数名为 name（非 title）。method = thread/name/set。
struct ThreadSetNameParams: Codable {
    let threadId: String
    let name: String
}

/// rollback 语义：从末尾丢弃 numTurns 轮（≥1），非任意点回滚。
struct ThreadRollbackParams: Codable {
    let threadId: String
    let numTurns: Int
}

enum ThreadGoalStatus: String, Codable {
    case active, paused, blocked, usageLimited, budgetLimited, complete
}

struct ThreadGoalSetParams: Codable {
    let threadId: String
    var objective: String?
    var status: ThreadGoalStatus?
    var tokenBudget: Int?
}
struct ThreadGoalGetParams: Codable { let threadId: String }
struct ThreadGoalClearParams: Codable { let threadId: String }

struct ThreadGoal: Codable, Equatable {
    let threadId: String
    let objective: String
    let status: ThreadGoalStatus
    let createdAt: Int
    let updatedAt: Int
    let timeUsedSeconds: Int
    let tokensUsed: Int
    var tokenBudget: Int?
}

/// thread/goal/get 响应：goal 可为 null（未设目标）。
struct ThreadGoalGetResponse: Codable { let goal: ThreadGoal? }
/// thread/goal/set 响应：goal 必填。
struct ThreadGoalSetResponse: Codable { let goal: ThreadGoal }

/// thread/name/updated 广播 payload：字段名为 threadName（可空），非 name。
struct ThreadNameUpdatedNotification: Codable {
    let threadId: String
    var threadName: String?
}

/// thread/goal/updated 广播 payload。
struct ThreadGoalUpdatedNotification: Codable {
    let threadId: String
    let goal: ThreadGoal
    var turnId: String?
}
