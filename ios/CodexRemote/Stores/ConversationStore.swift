import Foundation
import Observation

enum ConversationLoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed
}

/// 当前 thread 的会话状态层：持有 JSONRPCClient，发起 resume/start/turn 请求，
/// 并订阅 notifications() 把每条流式事件经 ThreadReducer 归约进 `state`（@Observable 暴露给 UI）。
///
/// 归约逻辑全部复用 `ThreadReducer`（Task 9），本类只负责接线与请求编码，不重写归约。
@Observable
@MainActor
final class ConversationStore {
    private(set) var state: ConversationState
    /// 流式内容每次合并落地递增一次。items 数量不变时，视图仍能感知正文增长。
    private(set) var contentRevision = 0
    private(set) var loadState: ConversationLoadState = .idle

    private let rpc: JSONRPCClient
    private let reducer = ThreadReducer()
    private var observer: Task<Void, Never>?
    /// #3：按需一次性延迟 flush 任务（非常驻循环）。有 pending 时不重复安排，drain 后清空。
    private var flushTask: Task<Void, Never>?
    /// 统一出站队列：合并原「忙队列 queuedInputs」与「离线队列 pendingOutbound」。二者本质同一件事
    /// 「发不出去先攒，能发时按序逐条发」，仅触发条件不同（忙=turn 占用 / 离线=未 .ready）。合成一条 +
    /// 单一 drain，消除两队列边界组合的 bug。每条入队即乐观回显（带 localId），drain 只 fire 不再回显。
    private let outbound: ConversationOutbox
    /// A rebuilt or reconnected store must not send against stale turn state. The connection-ready
    /// handler opens this gate only after thread/resume has supplied an authoritative answer.
    private var requiresAuthoritativeRecovery = false
    private var authoritativeRecoveryComplete = true
    private var recoveryGeneration: UInt64 = 0
    /// Permanent failures (for example a relay frame overflow) have already been isolated and cannot be retried.
    private(set) var lastSendErrorIsRetryable = true
    /// Compatibility/UI view of messages not yet fired. The shared owner also retains the in-flight entry
    /// internally until the RPC or authoritative clientId confirms it.
    var outbox: [PendingConversationMessage] { outbound.queuedEntries }
    var failedOutbound: PendingConversationMessage? { outbound.failedEntry }
    /// 当前连接是否 .ready 的信号源（装配时由 ConversationView 用 connection.phase 注入）。
    /// 默认 { true }：保持既有单测「无注入即视为在线直发」语义不变。
    var isReady: @MainActor () -> Bool = { true }

    init(rpc: JSONRPCClient, threadId: String, outbox: ConversationOutbox = ConversationOutbox()) {
        self.rpc = rpc
        self.outbound = outbox
        self.state = ConversationState(threadId: threadId)
        outbox.attach(to: rpc)
        for entry in outbox.entries {
            let presentation = Self.presentation(for: entry.input)
            state.items.append(.userMessage(
                id: entry.localId,
                text: presentation.text,
                attachments: presentation.attachments
            ))
        }
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
        let stream = await rpc.notifications(
            methods: ServerNotificationMethod.conversationMethods,
            threadId: state.threadId
        )
        observer = Task { [weak self] in
            for await n in stream {
                await MainActor.run {
                    guard let self else { return }
                    // 仅消费属于本线程的事件（按 params.threadId 过滤，缺省全收）。
                    guard self.belongsToThread(n) else { return }
                    if let clientId = Self.userMessageClientId(in: n) {
                        self.outbound.acknowledge(clientId: clientId)
                    }
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
        contentRevision &+= 1
    }

    /// 恢复桌面 app 创建的会话：发 thread/resume，加载并渲染历史。
    /// thread/resume 的同步响应里**携带完整历史**（thread.turns[].items[]）；
    /// 捕获该响应并经 ThreadReducer.ingest 灌入 state，UI 即可看到历史对话。
    func resume(model: String? = nil, cwd: String? = nil) async {
        await recoverCurrentThread(model: model, cwd: cwd)
    }

    /// 恢复当前可见 thread。全量 running-thread 订阅恢复由 ConnectionStore 每个 ready epoch 统一执行。
    func recoverCurrentThread(model: String? = nil, cwd: String? = nil) async {
        loadState = .loading
        requireAuthoritativeRecovery()
        recoveryGeneration &+= 1
        let generation = recoveryGeneration
        guard !state.threadId.isEmpty else {
            markAuthoritativeIdle()
            finishAuthoritativeRecovery(generation: generation)
            return
        }
        let params = ThreadResumeParams(threadId: state.threadId, model: model, cwd: cwd)
        do {
            let result = try await call(RPCMethod.threadResume, params)
            guard generation == recoveryGeneration else { return }
            guard let dict = result.value as? [String: Any] else {
                loadState = .failed
                return
            }
            reducer.ingest(resumeResult: dict, to: &state)
            acknowledgeOutbox(fromResumeResult: dict)
            if Self.resumeHasNoTurns(dict) { markAuthoritativeIdle() }
            finishAuthoritativeRecovery(generation: generation)
        } catch is CancellationError {
            if generation == recoveryGeneration { loadState = .idle }
        } catch {
            guard generation == recoveryGeneration else { return }
            if Self.isNoRollout(error) {
                markAuthoritativeIdle()
                finishAuthoritativeRecovery(generation: generation)
            } else {
                loadState = .failed
            }
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
    @discardableResult
    func send(input: [UserInput], model: String?, effort: ReasoningEffort?) async -> Bool {
        state.lastSendError = nil
        lastSendErrorIsRetryable = true
        // D3：乐观回显——发送即在本端插入用户消息，不等服务器广播。
        let entry: PendingConversationMessage
        do {
            entry = try outbound.enqueue(input: input, model: model, effort: effort)
        } catch {
            state.lastSendError = error.localizedDescription
            lastSendErrorIsRetryable = false
            return false
        }
        let (text, attachments) = Self.presentation(for: input)
        if !text.isEmpty || !attachments.isEmpty {
            reducer.upsertUserMessage(id: entry.localId, text: text,
                                      attachments: attachments, to: &state)
        }
        drainOutbox()
        return true
    }

    /// 出站队列 drain：一次只发一条，发出后靠 turn/started 建立的 sendInFlight 守卫 +
    /// isTurnRunning 天然串行化，等 turn/completed 才发下一条（daemon 同一 session 同时只跑一轮
    /// turn，并发 fire 会被 steer 合并/塌缩或丢弃——故绝不可一次性 fire 多条）。
    /// internal（非 private）供 View（.ready 触发）与测试直接调用。
    func drainOutbox() {
        guard isReady(),
              (!requiresAuthoritativeRecovery || authoritativeRecoveryComplete),
              !state.isTurnRunning,
              let next = outbound.beginSending() else { return }
        let params = TurnStartParams(threadId: state.threadId, input: next.input,
                                     clientUserMessageId: next.clientId,
                                     model: next.model, effort: next.effort, cwd: nil)
        Task { [self] in
            do {
                _ = try await call(RPCMethod.turnStart, params)
                outbound.finishSending(clientId: next.clientId)
            } catch {
                if Self.isPermanentSendFailure(error),
                   let discarded = outbound.discard(clientId: next.clientId) {
                    state.items.removeAll { $0.id == discarded.localId }
                    lastSendErrorIsRetryable = false
                    drainOutbox()
                } else if outbound.failSending(clientId: next.clientId) {
                    lastSendErrorIsRetryable = true
                } else {
                    // A matching authoritative userMessage already proved acceptance.
                    return
                }
                state.lastSendError = "\(error)"
            }
        }
    }

    /// turn events can originate from another client. They may trigger a drain attempt, but must never
    /// acknowledge this client's entry; only RPC success or a matching clientId may do that.
    private func handleOutboxTriggers(_ n: JSONRPCNotification) {
        switch n.method {
        case ServerNotificationMethod.turnCompleted:
            outbound.releaseAcceptedSendingWindow()
            drainOutbox()
        default:
            break
        }
    }

    /// D2：失败重发（失败项已原样留在 outbox 头且已回显）——重发即再 drain 一次，
    /// 不再二次回显、不再二次入队（#2 修复：旧实现经 send() 重发会重复 upsert 用户消息）。
    func retryLastSend() async {
        guard outbound.retryFailed() else { return }
        state.lastSendError = nil
        drainOutbox()
    }

    @discardableResult
    func discardFailedSend() -> PendingConversationMessage? {
        guard let entry = outbound.discardFailed() else { return nil }
        state.items.removeAll { $0.id == entry.localId }
        state.lastSendError = nil
        drainOutbox()
        return entry
    }

    func takeFailedSendForEditing() -> PendingConversationMessage? {
        discardFailedSend()
    }

    /// Close the send window before a new RPC binding or physical reconnect becomes usable.
    func requireAuthoritativeRecovery() {
        requiresAuthoritativeRecovery = true
        authoritativeRecoveryComplete = false
    }

    private static func isPermanentSendFailure(_ error: Error) -> Bool {
        guard let transportError = error as? TransportError else { return false }
        if case .messageTooLarge = transportError { return true }
        return false
    }

    // MARK: - private

    /// 缺省 threadId 全收；带 threadId 时只收本线程。
    private func belongsToThread(_ n: JSONRPCNotification) -> Bool {
        guard let p = n.params?.value as? [String: Any],
              let tid = p["threadId"] as? String else { return true }
        return tid == state.threadId
    }

    private static func presentation(for input: [UserInput]) ->
        (text: String, attachments: [UserMessageAttachment]) {
        let text = input.compactMap { if case .text(let value) = $0 { return value } else { return nil } }.joined()
        let attachments = input.compactMap { value -> UserMessageAttachment? in
            switch value {
            case .image(let url, _): return UserMessageAttachment(kind: .image, source: url)
            case .localImage(let path, _): return UserMessageAttachment(kind: .localImage, source: path)
            case .text: return nil
            }
        }
        return (text, attachments)
    }

    private static func userMessageClientId(in notification: JSONRPCNotification) -> String? {
        guard notification.method == ServerNotificationMethod.itemStarted,
              let params = notification.params?.value as? [String: Any],
              let item = params["item"] as? [String: Any],
              item["type"] as? String == "userMessage" else { return nil }
        return item["clientId"] as? String
    }

    private func acknowledgeOutbox(fromResumeResult result: [String: Any]) {
        let thread = result["thread"] as? [String: Any]
        let turns = (thread?["turns"] as? [[String: Any]]) ?? (result["turns"] as? [[String: Any]]) ?? []
        for turn in turns {
            for item in turn["items"] as? [[String: Any]] ?? [] where item["type"] as? String == "userMessage" {
                if let clientId = item["clientId"] as? String { outbound.acknowledge(clientId: clientId) }
            }
        }
    }

    private static func hasAuthoritativeTurnState(_ result: [String: Any]) -> Bool {
        let thread = result["thread"] as? [String: Any]
        let turns = (thread?["turns"] as? [[String: Any]]) ?? (result["turns"] as? [[String: Any]]) ?? []
        return turns.last?["status"] != nil
    }

    private static func resumeHasNoTurns(_ result: [String: Any]) -> Bool {
        let thread = result["thread"] as? [String: Any]
        let turns = (thread?["turns"] as? [[String: Any]]) ?? (result["turns"] as? [[String: Any]])
        return turns?.isEmpty == true
    }

    private static func isNoRollout(_ error: Error) -> Bool {
        guard let transportError = error as? TransportError,
              case .proxyFailed(let message) = transportError else { return false }
        return message.localizedCaseInsensitiveContains("no rollout")
    }

    private func markAuthoritativeIdle() {
        state.activeTurnId = nil
        state.activeTurnKind = nil
        state.inFlightItemIds.removeAll()
    }

    private func finishAuthoritativeRecovery(generation: UInt64) {
        guard generation == recoveryGeneration else { return }
        authoritativeRecoveryComplete = true
        loadState = .loaded
        reconcileOutboundAfterAuthoritativeResume()
    }

    /// A successful authoritative resume supersedes the pre-disconnect send window.
    /// If the restored turn is running, state blocks draining; if it is idle, the next queued item may proceed.
    func reconcileOutboundAfterAuthoritativeResume() {
        outbound.reconcileAuthoritativeState()
        drainOutbox()
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
    /// 无 threadId 或 `.turn` 且 turnDiff 为空时不发请求。返回 RPC 是否成功完成，
    /// 使 UI 不会在断线、服务端拒绝或协议错误时误报“已开始”。
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
            let format = L10n.string("review.turnInstructions", locale: LocaleManager.currentLocale)
            target = .custom(instructions: String(format: format, state.turnDiff))
        }

        let params = ReviewStartParams(threadId: threadId, target: target, delivery: .inline)
        do {
            _ = try await call(RPCMethod.reviewStart, params)
            return true
        } catch {
            return false
        }
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
        do {
            _ = try await call(RPCMethod.turnSteer, params)
            return true
        } catch {
            return false
        }
    }

    /// 排队后续输入：经统一 send 入 outbox（入队即回显、保留 model/effort）。
    /// turn 进行中时 drainOutbox 被 isTurnRunning 挡住，turn/completed 后自动出队发送。
    func enqueue(input: [UserInput], model: String? = nil, effort: ReasoningEffort? = nil) async {
        await send(input: input, model: model, effort: effort)
    }

    /// 中断进行中的 turn：发 turn/interrupt（threadId）。
    func interrupt() async {
        let params = TurnInterruptParams(threadId: state.threadId)
        guard let data = try? JSONEncoder().encode(params),
              let any = try? JSONDecoder().decode(AnyCodable.self, from: data) else { return }
        try? await rpc.sendWithoutWaiting(method: RPCMethod.turnInterrupt, params: any)
    }
}
