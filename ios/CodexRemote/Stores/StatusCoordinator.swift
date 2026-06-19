import Foundation
import Observation

/// 把全局会话状态 notification 接到 ProjectsStore（设计 D3，仿 ApprovalCoordinator）。
///
/// 职责：
///   - bind(rpc:)：连接建立/重连后调用。先 await notifications() 完成订阅注册，再起消费 Task
///     （与 ApprovalCoordinator 同源的多播订阅注册竞态修复：避免「注册晚于到达」丢事件）。
///   - 消费 thread/status/changed / turn/started / turn/completed，按 threadId 写 ProjectsStore：
///       · turn/started        → live = .running
///       · turn/completed      → live = .none，并 recordOutcome（completed/failed）
///       · thread/status/changed → live = LiveStatus.from(status)
///   - 断线不清空 liveStatus（B7）：本类不主动 setNone，保留最后已知态。
///   - 重连（B6）：RootView 在 rpcIdentity 变化时重 bind + 重新 loadFromServer 回填。
@MainActor
final class StatusCoordinator {
    private let projects: ProjectsStore
    private var notificationTask: Task<Void, Never>?

    init(projects: ProjectsStore) {
        self.projects = projects
    }

    /// 绑定到一个新的 rpc（连接建立/重连后调用）。先注册订阅再起消费循环。
    func bind(rpc: JSONRPCClient) async {
        let stream = await rpc.notifications()
        notificationTask?.cancel()
        notificationTask = Task { [weak self] in
            for await n in stream {
                await MainActor.run { self?.handle(n) }
            }
        }
    }

    /// 单条 notification → ProjectsStore 副作用（同步纯接线，便于单测）。
    func handle(_ n: JSONRPCNotification) {
        let p = (n.params?.value as? [String: Any]) ?? [:]
        guard let tid = p["threadId"] as? String else { return }
        switch n.method {
        case ServerNotificationMethod.turnStarted:
            projects.setLiveStatus(tid, .running)

        case ServerNotificationMethod.turnCompleted:
            projects.setLiveStatus(tid, .none)
            let turn = p["turn"] as? [String: Any]
            let status = (turn?["status"] as? String) ?? "completed"
            // M1：只对明确的 completed/failed 记结局；interrupted/inProgress/未知不记
            // （TurnStatus = completed|interrupted|failed|inProgress）——避免 interrupted 误亮绿点。
            switch status {
            case "completed": projects.recordOutcome(tid, outcome: .completed)
            case "failed":    projects.recordOutcome(tid, outcome: .failed)
            default:          break   // 仅清实时态，不记结局
            }

        case ServerNotificationMethod.statusChanged:
            let status = p["status"] as? [String: Any]
            let type = (status?["type"] as? String) ?? "idle"
            let flags = (status?["activeFlags"] as? [String]) ?? []
            projects.setLiveStatus(tid, LiveStatus.from(threadStatus: type, activeFlags: flags))

        default:
            break
        }
    }
}
