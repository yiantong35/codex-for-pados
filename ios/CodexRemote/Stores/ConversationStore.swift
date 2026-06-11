import Foundation
import Observation

/// 当前 thread 的会话状态层：持有 JSONRPCClient，发起 resume/start/turn 请求，
/// 并订阅 notifications() 把每条流式事件经 ThreadReducer 归约进 `state`（@Observable 暴露给 UI）。
///
/// 归约逻辑全部复用 `ThreadReducer`（Task 9），本类只负责接线与请求编码，不重写归约。
@Observable
@MainActor
final class ConversationStore {
    private(set) var state: ConversationState
    /// Task 17 排队用：turn 进行中收到的输入暂存，turn 结束后自动出队发送。
    var queuedInputs: [[UserInput]] = []

    private let rpc: JSONRPCClient
    private let reducer = ThreadReducer()
    private var observer: Task<Void, Never>?

    init(rpc: JSONRPCClient, threadId: String) {
        self.rpc = rpc
        self.state = ConversationState(threadId: threadId)
    }

    /// 当前 thread id（供 Task 17 steer/interrupt 用）。
    var threadId: String { state.threadId }
    /// 当前活跃 turn id（从 turn/started 通知取，供 Task 17 steer 用）。
    var activeTurnId: String? { state.activeTurnId }

    /// 订阅 notifications() 流，逐条归约进 state。重复调用是幂等的。
    func startObserving() {
        guard observer == nil else { return }
        observer = Task { [weak self] in
            guard let self else { return }
            let stream = await self.rpc.notifications()
            for await n in stream {
                await MainActor.run {
                    // 仅消费属于本线程的事件（按 params.threadId 过滤，缺省全收）。
                    guard self.belongsToThread(n) else { return }
                    self.reducer.apply(n, to: &self.state)
                    self.drainQueueIfTurnEnded(n)
                }
            }
        }
    }

    func stopObserving() {
        observer?.cancel()
        observer = nil
    }

    /// 恢复桌面 app 创建的会话：发 thread/resume，加载历史。
    /// 响应含历史 item，可在此灌入 state（MVP：依赖后续 read/通知补全）。
    /// 发出请求后立即返回；响应/历史经 notifications 流式归约，不阻塞 UI 等待同步响应。
    func resume(model: String? = nil, cwd: String? = nil) async {
        let params = ThreadResumeParams(threadId: state.threadId, model: model, cwd: cwd)
        Task { _ = try? await call(RPCMethod.threadResume, params) }
    }

    /// 新建对话：发 thread/start。返回的新 threadId 异步写回 state。
    func start(cwd: String? = nil, model: String? = nil) async {
        let params = ThreadStartParams(cwd: cwd, model: model)
        Task {
            guard let result = try? await call(RPCMethod.threadStart, params) else { return }
            if let dict = result.value as? [String: Any],
               let newId = dict["threadId"] as? String {
                state.threadId = newId
            }
        }
    }

    /// 发送 prompt：发 turn/start。turn 输出经 notifications 流式回来，故发出即返回。
    func send(input: [UserInput], model: String?, effort: ReasoningEffort?) async {
        let params = TurnStartParams(threadId: state.threadId, input: input,
                                     model: model, effort: effort, cwd: nil)
        Task { _ = try? await call(RPCMethod.turnStart, params) }
    }

    // MARK: - private

    /// 缺省 threadId 全收；带 threadId 时只收本线程。
    private func belongsToThread(_ n: JSONRPCNotification) -> Bool {
        guard let p = n.params?.value as? [String: Any],
              let tid = p["threadId"] as? String else { return true }
        return tid == state.threadId
    }

    private func drainQueueIfTurnEnded(_ n: JSONRPCNotification) {
        guard n.method == ServerNotificationMethod.turnCompleted,
              !queuedInputs.isEmpty else { return }
        let next = queuedInputs.removeFirst()
        Task { await send(input: next, model: nil, effort: nil) }
    }

    /// Encodable 参数 → AnyCodable → rpc.send。桥接模式同 ConnectionStore。
    private func call<T: Encodable>(_ method: String, _ params: T) async throws -> AnyCodable {
        let data = try JSONEncoder().encode(params)
        let any = try JSONDecoder().decode(AnyCodable.self, from: data)
        return try await rpc.send(method: method, params: any)
    }
}
