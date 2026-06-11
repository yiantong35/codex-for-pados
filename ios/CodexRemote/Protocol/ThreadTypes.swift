import Foundation

enum ReasoningEffort: String, Codable {
    case none, minimal, low, medium, high, xhigh
}

// 取自 v2/Thread.ts 子集。真实 thread/list 返回的 Thread 含大量嵌套字段
// (status/source/threadSource/gitInfo/turns 等)；MVP 仅建模渲染所需字段，
// 其余字段由 Swift Codable 默认忽略多余 JSON key 的行为容错跳过。
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
