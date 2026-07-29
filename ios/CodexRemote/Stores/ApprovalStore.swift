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
        let isPerms = req.method == ServerRequestMethod.permsApprovalV2

        // F4：解析权限请求的知情要素（reason + network/fileSystem 条目 + cwd）。
        let permsDict = p["permissions"] as? [String: Any]
        let netDict = permsDict?["network"] as? [String: Any]
        let netEnabled = netDict?["enabled"] as? Bool
        let fsDict = permsDict?["fileSystem"] as? [String: Any]
        let fsRead = fsDict?["read"] as? [String]
        let fsWrite = fsDict?["write"] as? [String]
        let fsEntries = (fsRead ?? []) + (fsWrite ?? [])
        // F4-fix：构造原样授权所需的请求档案（network 存在才承载、fileSystem 存在才承载），
        // 使批准时按请求精确授予，杜绝硬编码 network 过授。
        let requestedProfile: RequestPermissionProfile? = {
            guard isPerms else { return nil }
            let net = netDict != nil ? AdditionalNetworkPermissions(enabled: netEnabled) : nil
            let fs = fsDict != nil ? AdditionalFileSystemPermissions(read: fsRead, write: fsWrite) : nil
            return (net != nil || fs != nil) ? RequestPermissionProfile(network: net, fileSystem: fs) : nil
        }()

        let title: String
        if isFile {
            title = p["file"] as? String ?? String(localized: "approval.fallback.file")
        } else if isPerms {
            title = String(localized: "approval.permissionTitle")
        } else {
            title = p["command"] as? String ?? String(localized: "approval.fallback.command")
        }
        let detail: String
        if isFile {
            detail = p["diff"] as? String ?? ""
        } else {
            detail = p["cwd"] as? String ?? ""   // 命令与权限均以 cwd 作明细
        }

        let card = ApprovalCard(
            id: req.id,
            method: req.method,
            threadId: threadId,
            title: title,
            detail: detail,
            proposedPrefix: p["proposedExecpolicyAmendment"] as? [String],
            isFileChange: isFile,
            isPermissions: isPerms,
            reason: isPerms ? (p["reason"] as? String) : nil,
            requestedNetworkEnabled: isPerms ? netEnabled : nil,
            requestedFileSystem: isPerms && !fsEntries.isEmpty ? fsEntries : nil,
            requestedProfile: requestedProfile)
        cards.append(card)
        onPendingChange?(threadId, true)
    }

    // MARK: - 用户决定回传

    func resolve(card: ApprovalCard, choice: ApprovalChoice) async {
        let body = responseBody(for: card.method, decision: choice, requestedProfile: card.requestedProfile)
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
