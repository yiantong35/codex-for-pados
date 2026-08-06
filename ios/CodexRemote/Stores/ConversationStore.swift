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

    private let rpc: JSONRPCClient
    private let reducer = ThreadReducer()
    private var observer: Task<Void, Never>?
    /// #3：按需一次性延迟 flush 任务（非常驻循环）。有 pending 时不重复安排，drain 后清空。
    private var flushTask: Task<Void, Never>?
    /// D3：乐观回显临时 id 单调序号（同会话内唯一，用于与权威回显对账）。
    private var optimisticSeq = 0
    /// 统一出站队列：合并原「忙队列 queuedInputs」与「离线队列 pendingOutbound」。二者本质同一件事
    /// 「发不出去先攒，能发时按序逐条发」，仅触发条件不同（忙=turn 占用 / 离线=未 .ready）。合成一条 +
    /// 单一 drain，消除两队列边界组合的 bug。每条入队即乐观回显（带 localId），drain 只 fire 不再回显。
    private(set) var outbox: [(input: [UserInput], model: String?, effort: ReasoningEffort?, localId: String)] = []
    /// drain fire 后、turn/started 到达前的并发窗口守卫：置真则 drain 不发下一条，
    /// 由 turn/started（此后被 isTurnRunning 挡住）或 turn/completed 清零。防「一次 fire 多条」。
    private var sendInFlight = false
    /// 当前连接是否 .ready 的信号源（装配时由 ConversationView 用 connection.phase 注入）。
    /// 默认 { true }：保持既有单测「无注入即视为在线直发」语义不变。
    var isReady: @MainActor () -> Bool = { true }

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
                    self.handleOutboxTriggers(n)
                    self.scheduleFlushIfNeeded()   // #3：有脏 delta 才安排一次延迟 flush
                }
            }
        }
    }

    func stopObserving() {
        observer?.cancel()
        observer = nil
        flushTask?.cancel()
        flushTask = nil
        flushCoalesced()   // #3：兜底最后一次落地，不丢尾字。
    }

    // MARK: - #3：流式攒批按需调度（约 30Hz，空闲零唤醒）

    /// 有脏 delta 且当前无 pending flush 时，安排一次 33ms 后的 flush；drain 后不自动续期。
    /// 空闲（coalescer 为空）→ 早退，flushTask 保持 nil，对主线程零唤醒。
    /// 活跃流：首个 delta 安排一次 flush，期间到达的 delta 因 flushTask != nil 不重复安排，
    /// 33ms 到点一次合并（约 30Hz 攒批，避免逐条 O(n²)）；drain 后清 flushTask，下批再调度。
    private func scheduleFlushIfNeeded() {
        guard flushTask == nil, !reducer.coalescer.isEmpty else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 33_000_000)
            guard let self, !Task.isCancelled else { return }
            self.flushTask = nil        // 先清 pending 标志，再 drain：下批脏数据可重新调度
            self.flushCoalesced()
        }
    }

    #if DEBUG
    /// 测试专用只读访问器：当前是否有已安排、尚未落地的延迟 flush。
    /// `flushTask` 本身对生产代码保持 private；仅测试经 `@testable import` 需要可见性。
    var hasPendingFlushForTesting: Bool { flushTask != nil }
    #endif

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
            self.drainOutbox()
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

    /// 发送 prompt：唯一用户输入入口（三态统一——在线直发/忙队列/离线队列本质同一件事）。
    /// 入队即乐观回显（D3），然后交给 drainOutbox 决定是否能立即 fire：
    /// isReady()=false（未连接）或 isTurnRunning（turn 占用）或 sendInFlight（上一条尚未拿到
    /// turn/started）时留在 outbox 里，之后按序逐条补发（reconnect-resync item 3 + Task 17 排队）。
    func send(input: [UserInput], model: String?, effort: ReasoningEffort?) async {
        state.lastSendError = nil
        // D3：乐观回显——发送即在本端插入用户消息，不等服务器广播。
        optimisticSeq += 1
        let localId = "local-\(optimisticSeq)"
        let text = input.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined()
        if !text.isEmpty {
            reducer.upsertUserMessage(id: localId, text: text, to: &state)
        }
        outbox.append((input, model, effort, localId))
        drainOutbox()
    }

    /// 出站队列 drain：一次只发一条，发出后靠 turn/started 建立的 sendInFlight 守卫 +
    /// isTurnRunning 天然串行化，等 turn/completed 才发下一条（daemon 同一 session 同时只跑一轮
    /// turn，并发 fire 会被 steer 合并/塌缩或丢弃——故绝不可一次性 fire 多条）。
    /// internal（非 private）供 View（.ready 触发）与测试直接调用。
    func drainOutbox() {
        guard isReady(), !sendInFlight, !state.isTurnRunning, let next = outbox.first else { return }
        outbox.removeFirst()
        sendInFlight = true
        let params = TurnStartParams(threadId: state.threadId, input: next.input,
                                     model: next.model, effort: next.effort, cwd: nil)
        Task { [weak self] in
            do {
                _ = try await self?.call(RPCMethod.turnStart, params)
                // 成功：sendInFlight 由 turn/started / turn/completed 通知清零。
            } catch {
                guard let self else { return }
                self.outbox.insert(next, at: 0)   // 原样退回队首（已回显，不重复 upsert）
                self.sendInFlight = false
                self.state.lastSendError = "\(error)"
            }
        }
    }

    /// reconnect-resync item 3 + Task 17：turn/started 到达即解除并发窗口守卫（后续 drain 被
    /// isTurnRunning 挡住，天然串行）；turn/completed 到达即清零守卫并 drain 下一条。
    private func handleOutboxTriggers(_ n: JSONRPCNotification) {
        switch n.method {
        case ServerNotificationMethod.turnStarted:
            sendInFlight = false
        case ServerNotificationMethod.turnCompleted:
            sendInFlight = false
            drainOutbox()
        default:
            break
        }
    }

    /// D2：失败重发（失败项已原样留在 outbox 头且已回显）——重发即再 drain 一次，
    /// 不再二次回显、不再二次入队（#2 修复：旧实现经 send() 重发会重复 upsert 用户消息）。
    func retryLastSend() async { drainOutbox() }

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
        // #3 权威对账已在上面的 ingest(resumeResult:) 里按 turn.status 权威重置运行态
        // （漏收 turn/completed 时清 activeTurnId/inFlightItemIds → isTurnRunning 转 false）。
        // 此处 drainOutbox 补发断线期间因「假的真」运行态而积压的 send。
        drainOutbox()
    }

    // MARK: - private

    /// 缺省 threadId 全收；带 threadId 时只收本线程。
    private func belongsToThread(_ n: JSONRPCNotification) -> Bool {
        guard let p = n.params?.value as? [String: Any],
              let tid = p["threadId"] as? String else { return true }
        return tid == state.threadId
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

    /// 排队后续输入：经统一 send 入 outbox（入队即回显、保留 model/effort）。
    /// turn 进行中时 drainOutbox 被 isTurnRunning 挡住，turn/completed 后自动出队发送。
    func enqueue(input: [UserInput], model: String? = nil, effort: ReasoningEffort? = nil) async {
        await send(input: input, model: model, effort: effort)
    }

    /// 中断进行中的 turn：发 turn/interrupt（threadId）。
    func interrupt() async {
        let params = TurnInterruptParams(threadId: state.threadId)
        Task { _ = try? await call(RPCMethod.turnInterrupt, params) }
    }
}
