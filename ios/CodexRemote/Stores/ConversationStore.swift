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
    /// F8：30Hz（33ms）攒批发布定时任务。随 startObserving 起、stopObserving 停。
    private var coalesceTask: Task<Void, Never>?
    /// D2：最近一次发送的输入暂存，供失败重发（retryLastSend）。
    private var lastSent: (input: [UserInput], model: String?, effort: ReasoningEffort?)?
    /// D3：乐观回显临时 id 单调序号（同会话内唯一，用于与权威回显对账）。
    private var optimisticSeq = 0

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
        startCoalesceTimer()   // F8：起 30Hz 攒批发布定时器
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
        coalesceTask?.cancel()
        coalesceTask = nil
        flushCoalesced()   // F8：强制最后一次落地，兜底不丢尾字。
    }

    // MARK: - F8：流式攒批发布（30Hz）

    /// 30Hz（33ms）定时 drain → applyCoalesced → 一次 `state` 发布，消除每 token 全量刷新风暴。
    /// Task 建在 @MainActor 上下文，故 flushCoalesced 与 reducer.apply 内的 drain 同在主线程、互斥安全。
    private func startCoalesceTimer() {
        guard coalesceTask == nil else { return }
        coalesceTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 33_000_000)
                if Task.isCancelled { break }
                self?.flushCoalesced()
            }
        }
    }

    /// 把攒批缓冲一次性并入 state 并发布一次（无脏项则不发布）。
    private func flushCoalesced() {
        let drained = reducer.coalescer.drain()
        guard !drained.isEmpty else { return }
        var s = state
        reducer.applyCoalesced(drained, &s)
        state = s   // 一次发布，非每 token。
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

    /// fork 结果：新侧聊 threadId + daemon 记录的父指针（forkedFromId，用于标题展示）。
    struct ForkResult: Equatable {
        let threadId: String
        let forkedFromId: String?
    }

    /// 派生当前对话：发 thread/fork，得到新 thread（不影响源 thread）。
    /// `ephemeral` 默认 false —— 现有侧栏持久 fork 行为不变（编码时省略 ephemeral 键）；
    /// 侧聊路径传 true → 请求带 ephemeral、daemon 不落盘。返回新 threadId + forkedFromId（失败 nil）。
    @discardableResult
    func fork(ephemeral: Bool = false) async -> ForkResult? {
        // false → nil：省略 ephemeral 键，保持旧持久 fork 的线格式不变（直接传 Bool 会写出 "ephemeral":false）
        let params = ThreadForkParams(threadId: state.threadId, ephemeral: ephemeral ? true : nil)
        guard let result = try? await call(RPCMethod.threadFork, params),
              let resp = try? decode(ForkedThreadResponse.self, from: result) else { return nil }
        return ForkResult(threadId: resp.thread.id, forkedFromId: resp.thread.forkedFromId)
    }

    /// 发送 prompt：发 turn/start。turn 输出经 notifications 流式回来，故发出即返回。
    func send(input: [UserInput], model: String?, effort: ReasoningEffort?) async {
        state.lastSendError = nil
        // D3：乐观回显——发送即在本端插入用户消息，不等服务器广播。
        optimisticSeq += 1
        let localId = "local-\(optimisticSeq)"
        let text = input.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined()
        if !text.isEmpty {
            reducer.upsertUserMessage(id: localId, text: text, to: &state)
        }
        lastSent = (input, model, effort)   // D2：暂存以支持失败重发
        let params = TurnStartParams(threadId: state.threadId, input: input,
                                     model: model, effort: effort, cwd: nil)
        Task { [weak self] in
            do {
                _ = try await self?.call(RPCMethod.turnStart, params)
            } catch {
                self?.state.lastSendError = "\(error)"
            }
        }
    }

    /// D2：重发最近一次发送（失败后由 UI 错误条触发）；无暂存则无操作。
    func retryLastSend() async {
        guard let last = lastSent else { return }
        await send(input: last.input, model: last.model, effort: last.effort)
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

// MARK: - 审查面板：全量 diff 拉取（gitDiffToRemote）

extension ConversationStore {
    /// 拉取远端仓库全量 diff（发 gitDiffToRemote{cwd}），返回 unified diff 字符串。
    /// 失败（传输错误 / 解码失败）返回 nil，由调用方降级为空态。
    func fetchFullDiff(cwd: String) async -> String? {
        let params = GitDiffToRemoteParams(cwd: cwd)
        guard let result = try? await call(RPCMethod.gitDiffToRemote, params),
              let resp = try? decode(GitDiffToRemoteResponse.self, from: result) else { return nil }
        return resp.diff
    }
}

// MARK: - 审查发起（review/start，设计 D2/D3/D4）

extension ConversationStore {
    /// 发起一轮 AI 审查（review/start，inline 投递，结果经通知流回主对话回显）。
    /// - `.full` → target: uncommittedChanges（服务端算工作区改动，不传 diff 文本）
    /// - `.turn` → target: custom{instructions: turnDiff}（协议无「某一轮」原生 target）
    /// 无 threadId 或 `.turn` 且 turnDiff 为空时不发请求。返回是否发出（供入口禁用/测试断言）。
    @discardableResult
    func startReview(mode: ReviewSourceMode) async -> Bool {
        let threadId = state.threadId
        guard !threadId.isEmpty else { return false }

        let target: ReviewTarget
        switch mode {
        case .full:
            target = .uncommittedChanges
        case .turn:
            let diff = state.turnDiff.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !diff.isEmpty else { return false }
            target = .custom(instructions: "请审查以下改动：\n\(state.turnDiff)")
        }

        let params = ReviewStartParams(threadId: threadId, target: target, delivery: .inline)
        Task { [weak self] in _ = try? await self?.call(RPCMethod.reviewStart, params) }
        return true
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
