import Foundation
import Observation

/// UI 层统一的三选项决定，落地时按方法映射到 v2/legacy 的不同 decision 形状。
enum ApprovalChoice: Equatable {
    case approve                            // 是
    case approveForSessionPrefix([String])  // 是，且此前缀本会话不再询问
    case deny                               // 否
}

/// 统一审批卡模型：v2 三类 + legacy 两类审批请求解析后的展示数据。
struct ApprovalCard: Identifiable {
    let id: RequestId
    let method: String
    let threadId: String
    let title: String               // 命令文本或文件名
    let detail: String              // 命令明细(cwd)或 diff 摘要
    let proposedPrefix: [String]?   // v2 命令审批可能携带 proposedExecpolicyAmendment
    let isFileChange: Bool
    var awaitingRecovery: Bool = false   // Task 19：断线未决标记
}

/// 审批状态层（设计 §6）：把 server→client 审批请求统一成 ApprovalCard 入队，
/// 提供 approve / approveForSession(前缀放行) / deny，按请求类型构造正确 decision 经 resolver 回传。
///
/// resolver 由接线方注入（实际调用 `rpc.respond(to:result:)`）。绝不在断线/他端解决时自动批准。
@Observable
@MainActor
final class ApprovalStore {
    private(set) var cards: [ApprovalCard] = []

    /// 回传响应的回调，由接线方注入（实际调用 rpc.respond）。
    var resolver: (@MainActor (RequestId, AnyCodable) async -> Void)?
    /// 通知 ProjectsStore 更新徽标。
    var onPendingChange: (@MainActor (_ threadId: String, _ pending: Bool) -> Void)?

    // MARK: - 接收审批请求

    /// 解析一条 server→client 审批请求（v2 三类 + legacy 两类）入队。
    func handle(request req: JSONRPCRequest) {
        let p = (req.params?.value as? [String: Any]) ?? [:]
        let threadId = p["threadId"] as? String ?? ""
        let isFile = req.method == ServerRequestMethod.fileApprovalV2
                  || req.method == ServerRequestMethod.applyPatchApprovalLegacy
        let card = ApprovalCard(
            id: req.id,
            method: req.method,
            threadId: threadId,
            title: isFile ? (p["file"] as? String ?? "文件改动") : (p["command"] as? String ?? "命令"),
            detail: isFile ? (p["diff"] as? String ?? "") : (p["cwd"] as? String ?? ""),
            proposedPrefix: p["proposedExecpolicyAmendment"] as? [String],
            isFileChange: isFile)
        cards.append(card)
        onPendingChange?(threadId, true)
    }

    // MARK: - 用户决定回传

    func resolve(card: ApprovalCard, choice: ApprovalChoice) async {
        let body = responseBody(for: card.method, decision: choice)
        let any = (try? JSONDecoder().decode(AnyCodable.self, from: JSONEncoder().encode(body)))
            ?? AnyCodable([String: Any]())
        await resolver?(card.id, any)
        remove(card.id, threadId: card.threadId)
    }

    func remove(_ id: RequestId, threadId: String) {
        cards.removeAll { $0.id == id }
        if !cards.contains(where: { $0.threadId == threadId }) { onPendingChange?(threadId, false) }
    }

    /// 按请求方法把统一选项映射到正确的 decision 形状（v2 用 CommandExecution/FileChange，legacy 用 ReviewDecision）。
    func responseBody(for method: String, decision: ApprovalChoice) -> AnyEncodable {
        let isLegacy = method == ServerRequestMethod.execApprovalLegacy
                    || method == ServerRequestMethod.applyPatchApprovalLegacy
        let isFile = method == ServerRequestMethod.fileApprovalV2
        if isLegacy {
            let d: ReviewDecision
            switch decision {
            case .approve: d = .approved
            case .approveForSessionPrefix(let p): d = .approvedExecpolicyAmendment(proposed: p)
            case .deny: d = .denied
            }
            return AnyEncodable(ExecCommandApprovalResponse(decision: d))
        } else if isFile {
            // 文件审批无前缀放行语义，前缀选项降级为 acceptForSession。
            let d: FileChangeApprovalDecision
            switch decision {
            case .approve: d = .accept
            case .approveForSessionPrefix: d = .acceptForSession
            case .deny: d = .decline
            }
            return AnyEncodable(FileChangeApprovalResponse(decision: d))
        } else {
            let d: CommandExecutionApprovalDecision
            switch decision {
            case .approve: d = .accept
            case .approveForSessionPrefix(let p): d = .acceptWithExecpolicyAmendment(execpolicyAmendment: p)
            case .deny: d = .decline
            }
            return AnyEncodable(CommandExecutionApprovalResponse(decision: d))
        }
    }
}

// MARK: - Task 19：审批边界（serverRequest/resolved + 超时/断线不自动批准）

extension ApprovalStore {
    /// serverRequest/resolved：某审批被他端（如桌面 app）先处理 → 移除卡片，**不回传**任何决定。
    func handleServerRequestResolved(requestId: RequestId, threadId: String) {
        remove(requestId, threadId: threadId)
    }

    /// 连接中断：未决审批标记待恢复，**绝不自动批准**（不调用 resolver）。
    /// 重连后服务端可能重发审批请求，届时再次走 handle(request:) 重新展示。
    func handleConnectionLost() {
        for i in cards.indices { cards[i].awaitingRecovery = true }
    }
}

/// 类型擦除 Encodable，便于 responseBody 返回统一类型并直接编码。
struct AnyEncodable: Encodable {
    private let _encode: (Encoder) throws -> Void
    init<T: Encodable>(_ v: T) { _encode = v.encode }
    func encode(to e: Encoder) throws { try _encode(e) }
}
