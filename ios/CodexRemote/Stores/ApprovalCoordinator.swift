import Foundation
import Observation

/// 把 ApprovalStore 接到 JSONRPCClient 与 ConnectionStore（设计 §6 接线层）。
///
/// 职责：
///   - 订阅 `rpc.serverRequests()`：审批请求 → `ApprovalStore.handle(request:)`，
///     并把对应 continuation 暂存，等用户在 UI 选择后由 `resolver` 回填响应（经 `rpc.respond`）。
///   - 订阅 `rpc.notifications()`：`serverRequest/resolved` → 移除卡片（不回传）。
///   - 连接断开（phase=.reconnecting）→ `handleConnectionLost()`，绝不自动批准。
///   - 注入 `onPendingChange` 驱动 ProjectsStore 徽标。
@MainActor
final class ApprovalCoordinator {
    let store: ApprovalStore
    private let projects: ProjectsStore
    private var serverRequestTask: Task<Void, Never>?
    private var notificationTask: Task<Void, Never>?

    init(store: ApprovalStore, projects: ProjectsStore) {
        self.store = store
        self.projects = projects
        store.onPendingChange = { [weak projects] tid, pending in
            projects?.setPendingApproval(threadId: tid, pending: pending)
        }
    }

    /// 绑定到一个新的 rpc（连接建立/重连后调用）。直接经 rpc.respond 回传决定。
    func bind(rpc: JSONRPCClient) {
        store.resolver = { id, body in try? await rpc.respond(to: id, result: body) }

        serverRequestTask?.cancel()
        serverRequestTask = Task { [weak self] in
            let stream = await rpc.serverRequests()
            for await req in stream {
                guard let self else { return }
                if Self.isApproval(req.method) {
                    self.store.handle(request: req)
                }
            }
        }

        notificationTask?.cancel()
        notificationTask = Task { [weak self] in
            let stream = await rpc.notifications()
            for await n in stream {
                guard let self else { return }
                guard n.method == ServerNotificationMethod.serverRequestResolved else { continue }
                let p = (n.params?.value as? [String: Any]) ?? [:]
                guard let id = Self.requestId(from: p["requestId"]) else { continue }
                let tid = p["threadId"] as? String ?? ""
                self.store.handleServerRequestResolved(requestId: id, threadId: tid)
            }
        }
    }

    /// 连接断开：未决审批标记待恢复，绝不自动批准。
    func connectionLost() {
        store.handleConnectionLost()
    }

    private static func isApproval(_ method: String) -> Bool {
        switch method {
        case ServerRequestMethod.cmdApprovalV2,
             ServerRequestMethod.fileApprovalV2,
             ServerRequestMethod.permsApprovalV2,
             ServerRequestMethod.execApprovalLegacy,
             ServerRequestMethod.applyPatchApprovalLegacy:
            return true
        default:
            return false
        }
    }

    /// requestId 可能是 string 或 int（以真实帧为准，Task 20 录制核对）。
    private static func requestId(from any: Any?) -> RequestId? {
        if let s = any as? String { return .string(s) }
        if let i = any as? Int64 { return .int(i) }
        if let i = any as? Int { return .int(Int64(i)) }
        return nil
    }
}
