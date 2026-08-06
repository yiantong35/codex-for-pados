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
    // F4：权限审批（item/permissions/requestApproval）的知情展示要素。
    let isPermissions: Bool
    let reason: String?                     // 请求携带的授权理由（若有）
    let requestedNetworkEnabled: Bool?      // 请求的 network.enabled（若有）
    let requestedFileSystem: [String]?      // 请求的 fileSystem read+write 合并条目（若有，仅用于知情展示）
    // F4-fix：授权回显所需的完整请求档案（network/fileSystem 分列 read/write），批准时按此原样授予（最小权限）。
    var requestedProfile: RequestPermissionProfile? = nil
    var awaitingRecovery: Bool = false   // Task 19：断线未决标记
    var turnId: String? = nil
    var itemId: String? = nil
    var startedAtMs: Int64? = nil
    var networkApprovalContext: NetworkApprovalContext? = nil
    var proposedNetworkPolicyAmendments: [NetworkPolicyAmendment]? = nil
    var permissionEntries: [FileSystemSandboxEntry]? = nil
    var globScanMaxDepth: UInt? = nil
    var grantRoot: String? = nil
    var fileChanges: [String: AnyCodable]? = nil
    var approvalId: String? = nil
    var commandActions: [AnyCodable]? = nil
    var environmentId: String? = nil
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
    /// 返回 respond 是否送达成功：失败时 `resolve` 保留卡片供重试，绝不静默丢弃未决审批（fail-closed）。
    var resolver: (@MainActor (RequestId, AnyCodable) async -> Bool)?
    /// 通知 ProjectsStore 更新徽标。
    var onPendingChange: (@MainActor (_ threadId: String, _ pending: Bool) -> Void)?

    // MARK: - 接收审批请求

    /// 解析一条 server→client 审批请求（v2 三类 + legacy 两类）入队。
    func handle(request req: JSONRPCRequest) {
        try? handleValidated(request: req)
    }

    func handleValidated(request req: JSONRPCRequest) throws {
        let payload = try ApprovalRequestDecoder.decode(req)
        let card = makeCard(request: req, payload: payload)
        // reconnect-resync item 1：按 requestId 幂等收敛。
        // 命中既有卡 → 原地替换（新 card.awaitingRecovery 默认 false，等于清断线标记 + 刷新载荷）；
        // 未命中 → 保持既有 append。断线绝不在此自动批准/丢弃。
        if let idx = cards.firstIndex(where: { $0.id == req.id }) {
            cards[idx] = card
        } else {
            cards.append(card)
        }
        onPendingChange?(card.threadId, true)
    }

    private func makeCard(request: JSONRPCRequest, payload: ApprovalRequestPayload) -> ApprovalCard {
        switch payload {
        case .command(let params):
            return ApprovalCard(
                id: request.id, method: request.method, threadId: params.threadId,
                title: params.command ?? String(localized: "approval.fallback.command"), detail: params.cwd ?? "",
                proposedPrefix: params.proposedExecpolicyAmendment, isFileChange: false, isPermissions: false,
                reason: params.reason, requestedNetworkEnabled: nil, requestedFileSystem: nil,
                turnId: params.turnId, itemId: params.itemId, startedAtMs: params.startedAtMs,
                networkApprovalContext: params.networkApprovalContext,
                proposedNetworkPolicyAmendments: params.proposedNetworkPolicyAmendments,
                approvalId: params.approvalId, commandActions: params.commandActions)
        case .file(let params):
            return ApprovalCard(
                id: request.id, method: request.method, threadId: params.threadId,
                title: String(localized: "approval.fallback.file"), detail: "", proposedPrefix: nil,
                isFileChange: true, isPermissions: false, reason: params.reason,
                requestedNetworkEnabled: nil, requestedFileSystem: nil,
                turnId: params.turnId, itemId: params.itemId, startedAtMs: params.startedAtMs,
                grantRoot: params.grantRoot)
        case .permissions(let params):
            let fileSystem = params.permissions.fileSystem
            let legacyPaths = (fileSystem?.read ?? []) + (fileSystem?.write ?? [])
            let entryPaths = fileSystem?.entries?.map { $0.path.displayValue } ?? []
            return ApprovalCard(
                id: request.id, method: request.method, threadId: params.threadId,
                title: String(localized: "approval.permissionTitle"), detail: params.cwd,
                proposedPrefix: nil, isFileChange: false, isPermissions: true, reason: params.reason,
                requestedNetworkEnabled: params.permissions.network?.enabled,
                requestedFileSystem: (entryPaths + legacyPaths).isEmpty ? nil : entryPaths + legacyPaths,
                requestedProfile: params.permissions, turnId: params.turnId, itemId: params.itemId,
                startedAtMs: params.startedAtMs, permissionEntries: fileSystem?.entries,
                globScanMaxDepth: fileSystem?.globScanMaxDepth, environmentId: params.environmentId)
        case .legacyCommand(let params):
            return ApprovalCard(
                id: request.id, method: request.method, threadId: params.conversationId,
                title: params.command.joined(separator: " "), detail: params.cwd,
                proposedPrefix: nil, isFileChange: false, isPermissions: false, reason: params.reason,
                requestedNetworkEnabled: nil, requestedFileSystem: nil, itemId: params.callId,
                approvalId: params.approvalId, commandActions: params.parsedCmd)
        case .legacyPatch(let params):
            return ApprovalCard(
                id: request.id, method: request.method, threadId: params.conversationId,
                title: params.fileChanges.keys.sorted().joined(separator: ", "), detail: "",
                proposedPrefix: nil, isFileChange: true, isPermissions: false, reason: params.reason,
                requestedNetworkEnabled: nil, requestedFileSystem: nil, itemId: params.callId,
                grantRoot: params.grantRoot, fileChanges: params.fileChanges)
        }
    }

    // MARK: - 用户决定回传

    /// 用户决定回传。返回是否成功送达：
    /// 成功 → 移除卡片；失败（半开连接 respond 抛错/无 resolver）→ **保留卡片**并清 awaitingRecovery
    /// 以外的状态供重试，绝不静默 `remove` 未确认的审批（#6，fail-closed）。
    @discardableResult
    func resolve(card: ApprovalCard, choice: ApprovalChoice) async -> Bool {
        let body = responseBody(for: card.method, decision: choice, requestedProfile: card.requestedProfile)
        let any = (try? JSONDecoder().decode(AnyCodable.self, from: JSONEncoder().encode(body)))
            ?? AnyCodable([String: Any]())
        let delivered = await resolver?(card.id, any) ?? false
        if delivered {
            remove(card.id, threadId: card.threadId)
        }
        return delivered
    }

    func remove(_ id: RequestId, threadId: String) {
        cards.removeAll { $0.id == id }
        if !cards.contains(where: { $0.threadId == threadId }) { onPendingChange?(threadId, false) }
    }

    /// 按请求方法把统一选项映射到正确的 decision 形状（v2 用 CommandExecution/FileChange，legacy 用 ReviewDecision）。
    func responseBody(for method: String, decision: ApprovalChoice,
                      requestedProfile: RequestPermissionProfile? = nil) -> AnyEncodable {
        let isLegacy = method == ServerRequestMethod.execApprovalLegacy
                    || method == ServerRequestMethod.applyPatchApprovalLegacy
        let isFile = method == ServerRequestMethod.fileApprovalV2
        let isPerms = method == ServerRequestMethod.permsApprovalV2
        if isPerms {
            // F4：权限审批 MUST 返回 PermissionsRequestApprovalResponse（permissions+scope），
            // 绝不落命令执行审批的 { decision }。scope：approve→turn、按前缀放行→session、deny→turn。
            // F4-fix：批准即原样回显请求档案（network/fileSystem 各按请求授予），
            // 杜绝硬编码 network 过授、fileSystem 漏授（最小权限）；拒绝一律 fail-closed（不授予）。
            let scope: PermissionGrantScope
            let granted: GrantedPermissionProfile
            switch decision {
            case .approve:
                scope = .turn
                granted = GrantedPermissionProfile(network: requestedProfile?.network,
                                                   fileSystem: requestedProfile?.fileSystem)
            case .approveForSessionPrefix:
                scope = .session
                granted = GrantedPermissionProfile(network: requestedProfile?.network,
                                                   fileSystem: requestedProfile?.fileSystem)
            case .deny:
                scope = .turn
                granted = GrantedPermissionProfile(network: AdditionalNetworkPermissions(enabled: false), fileSystem: nil)
            }
            return AnyEncodable(PermissionsRequestApprovalResponse(
                permissions: granted, scope: scope, strictAutoReview: nil))
        }
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
