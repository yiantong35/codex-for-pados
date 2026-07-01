import Foundation

// MARK: - 全量 diff / 认证（批次⑤ 环境信息 inspector）

struct GitDiffToRemoteParams: Encodable { let cwd: String }
struct GitDiffToRemoteResponse: Decodable { let sha: String; let diff: String }

struct GetAuthStatusResponse: Decodable {
    var authMethod: String?
    var authToken: String?
    var requiresOpenaiAuth: Bool?
}

// MARK: - 子智能体

/// protocol v2 CollabAgentStatus。未知值兜底 notFound。
enum CollabAgentStatus: String, Codable, Equatable {
    case pendingInit, running, interrupted, completed, errored, shutdown, notFound
    static func from(_ s: String?) -> CollabAgentStatus { CollabAgentStatus(rawValue: s ?? "") ?? .notFound }
}

/// 当前会话内某子智能体的聚合状态。
struct SubAgentState: Equatable, Identifiable {
    let agentThreadId: String
    var path: String?
    var status: CollabAgentStatus
    var message: String?
    var id: String { agentThreadId }
    /// 展示名 = path 末段（item 无 name 字段，desktop 同此推断）。
    var displayName: String {
        guard let p = path, !p.isEmpty else { return String(agentThreadId.prefix(8)) }
        return (p as NSString).lastPathComponent
    }
}
