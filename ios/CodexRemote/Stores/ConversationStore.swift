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
    ///
    /// async：先 `await rpc.notifications()` 完成订阅注册（多播流的 continuation 在该调用
    /// 返回时即已登记进 actor），**再**起消费 Task。这样 `await startObserving()` 返回后，
    /// 订阅一定已就绪，之后到达的通知不会因「注册晚于通知」而丢失（修复多播订阅注册竞态：
    /// 旧实现把 `await notifications()` 放进游离 Task，函数同步返回时注册可能尚未完成）。
    func startObserving() async {
        guard observer == nil else { return }
        let stream = await rpc.notifications()
        observer = Task { [weak self] in
            for await n in stream {
                await MainActor.run {
                    guard let self else { return }
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

    /// 恢复桌面 app 创建的会话：发 thread/resume，加载并渲染历史。
    /// thread/resume 的同步响应里**携带完整历史**（thread.turns[].items[]）；
    /// 捕获该响应并经 ThreadReducer.ingest 灌入 state，UI 即可看到历史对话。
    /// 发出请求后立即返回，历史摄入在响应到达后于主线程异步完成，不阻塞 UI。
    func resume(model: String? = nil, cwd: String? = nil) async {
        let params = ThreadResumeParams(threadId: state.threadId, model: model, cwd: cwd)
        Task { [weak self] in
            guard let self else { return }
            guard let result = try? await self.call(RPCMethod.threadResume, params),
                  let dict = result.value as? [String: Any] else { return }
            self.reducer.ingest(resumeResult: dict, to: &self.state)
        }
    }

    /// 新建对话：发 thread/start。fire-and-forget——网络调用包进 Task{} 立即返回；
    /// 返回的新 threadId 异步写回 state。响应 shape 为 {thread:{id,...},...}（protocol v2）。
    func start(cwd: String? = nil, model: String? = nil) async {
        let params = ThreadStartParams(cwd: cwd, model: model)
        Task { [weak self] in
            guard let self else { return }
            guard let result = try? await self.call(RPCMethod.threadStart, params) else { return }
            if let dict = result.value as? [String: Any],
               let newId = (dict["thread"] as? [String: Any])?["id"] as? String {
                self.state.threadId = newId
            }
        }
    }

    /// 派生当前对话：发 thread/fork，得到新 thread id（不影响源 thread）。返回新 id（失败 nil）。
    /// 响应 shape 为 {thread:{id,...},...}（protocol v2 ThreadForkResponse）。
    @discardableResult
    func fork() async -> String? {
        let params = ThreadForkParams(threadId: state.threadId)
        guard let result = try? await call(RPCMethod.threadFork, params),
              let dict = result.value as? [String: Any],
              let newId = (dict["thread"] as? [String: Any])?["id"] as? String else { return nil }
        return newId
    }

    /// 发送 prompt：发 turn/start。turn 输出经 notifications 流式回来，故发出即返回。
    func send(input: [UserInput], model: String?, effort: ReasoningEffort?) async {
        let params = TurnStartParams(threadId: state.threadId, input: input,
                                     model: model, effort: effort, cwd: nil)
        Task { _ = try? await call(RPCMethod.turnStart, params) }
    }

    /// 重连/连接后经官方权威列表恢复（设计 D3）：
    /// 1) thread/loaded/list 拿当前 app-server 内存中运行的 thread ids（不依赖本地 threadId 作唯一依据）；
    /// 2) 对每个 id thread/resume —— 命中 running thread 时官方按 rejoin 重新加入（不 fork/不新建），
    ///    同时**自动订阅**该 thread（官方无显式 subscribe，start/resume 即订阅），之后才收其 turn/item 通知；
    /// 3) 单个 thread 尚未跑过 turn 时 resume 返回 `-32600 no rollout found`（经 call 抛 TransportError）
    ///    → 用 `try?` 吞掉并跳过，继续处理其余 thread，绝不因单个失败中断整批恢复（spike-findings §5）。
    /// 仅把命中当前 threadId 的 resume 历史灌入本 store 的 state；其余 thread 的订阅副作用仍生效。
    func rejoinRunningThreads() async {
        guard let listResult = try? await call(RPCMethod.threadLoadedList, EmptyParams()),
              let list = try? decode(LoadedThreadList.self, from: listResult) else { return }
        // 首页 data 已覆盖当前活跃 thread；翻页（nextCursor）留待需要时再实现。
        for tid in list.data {
            let params = ThreadResumeParams(threadId: tid, model: nil, cwd: nil)
            guard let r = try? await call(RPCMethod.threadResume, params),
                  let dict = r.value as? [String: Any] else { continue }   // no rollout 等单个失败：跳过
            if tid == state.threadId { reducer.ingest(resumeResult: dict, to: &state) }
        }
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
    /// internal（非 private）以便 Task 17 中途控制 extension 调用。
    func call<T: Encodable>(_ method: String, _ params: T) async throws -> AnyCodable {
        let data = try JSONEncoder().encode(params)
        let any = try JSONDecoder().decode(AnyCodable.self, from: data)
        return try await rpc.send(method: method, params: any)
    }

    /// AnyCodable → 具体 Decodable 类型（用于把 thread/loaded/list 等响应解成强类型）。
    private func decode<T: Decodable>(_ t: T.Type, from a: AnyCodable) throws -> T {
        let data = try JSONEncoder().encode(a)
        return try JSONDecoder().decode(t, from: data)
    }
}

// MARK: - Task 17：中途控制（steer / 排队 / interrupt）

extension ConversationStore {
    /// 转向当前进行中的 turn：发 turn/steer（threadId + input + expectedTurnId=activeTurnId）。
    /// 仅当 turn 进行中（activeTurnId 非空）且当前 turn 可 steer（activeTurnKind == nil，
    /// 即非 review/compact）时才发出。返回是否成功发出 steer。
    @discardableResult
    func steer(input: [UserInput]) async -> Bool {
        guard let turnId = state.activeTurnId, state.activeTurnKind == nil else { return false }
        let params = TurnSteerParams(threadId: state.threadId, input: input, expectedTurnId: turnId)
        Task { _ = try? await call(RPCMethod.turnSteer, params) }
        return true
    }

    /// 排队后续输入：turn 进行中时暂存，turn/completed 后由 drainQueueIfTurnEnded 自动出队发送。
    func enqueue(input: [UserInput]) {
        queuedInputs.append(input)
    }

    /// 中断进行中的 turn：发 turn/interrupt（threadId）。
    func interrupt() async {
        let params = TurnInterruptParams(threadId: state.threadId)
        Task { _ = try? await call(RPCMethod.turnInterrupt, params) }
    }
}
