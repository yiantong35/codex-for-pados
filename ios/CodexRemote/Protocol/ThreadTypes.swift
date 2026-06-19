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

/// ThreadStatus 子集（取自 v2/ThreadStatus.ts）。MVP 仅需 type + activeFlags 用于回填实时态。
struct ThreadStatusSummary: Codable, Equatable {
    var type: String?
    var activeFlags: [String]?
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
    let name: String?
    var gitInfo: GitInfoSummary?                    // null 表示非 git 仓库（分类信号，见 D8）
    /// thread/list 返回的会话状态（sidebar-status-badges D3 回填实时态）。缺省时容错为 nil。
    var status: ThreadStatusSummary?

    /// 派生：状态类型字符串，缺省回落 "idle"（B5 兜底）。
    var statusType: String { status?.type ?? "idle" }
    /// 派生：active flags，缺省空数组。
    var activeFlags: [String] { status?.activeFlags ?? [] }
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

struct ThreadStartParams: Codable {
    var cwd: String?
    var model: String?
}
