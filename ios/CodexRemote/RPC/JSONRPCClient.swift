import Foundation

struct DeferredServerRequestLimits: Sendable {
    let maximumTotalCount: Int
    let maximumPerOwnerCount: Int
    let maximumTotalBytes: Int

    init(maximumTotalCount: Int = 64,
         maximumPerOwnerCount: Int = 24,
         maximumTotalBytes: Int = 512 * 1_024) {
        self.maximumTotalCount = max(1, maximumTotalCount)
        self.maximumPerOwnerCount = max(1, min(maximumPerOwnerCount, maximumTotalCount))
        self.maximumTotalBytes = max(1, maximumTotalBytes)
    }
}

struct JSONRPCStreamLimits: Sendable {
    let notificationBufferCount: Int
    let serverRequestBufferCount: Int

    init(notificationBufferCount: Int = 256, serverRequestBufferCount: Int = 32) {
        self.notificationBufferCount = max(1, notificationBufferCount)
        self.serverRequestBufferCount = max(1, serverRequestBufferCount)
    }
}

/// JSON-RPC 客户端（actor）：消费 transport.incoming()，对每条 JSON 文本解码为
/// JSONRPCMessage 并分发：
///   - .response/.error → 按 id 唤醒等待中的 send(method:params:)（pending 表）
///   - .notification → yield 到对外通知流
///   - .request（server→client）→ 路由给唯一 owner，或立即回 method-not-found
actor JSONRPCClient {
    private let transport: MessageTransport
    private let deferredRequestLimits: DeferredServerRequestLimits
    private let streamLimits: JSONRPCStreamLimits
    private var pending: [RequestId: CheckedContinuation<AnyCodable, Error>] = [:]
    private enum DeferredState {
        case owned(ServerRequestOwner)
        case completing(ServerRequestOwner)
    }
    private var deferredServerRequests: [RequestId: DeferredState] = [:]
    private var deferredServerRequestPayloads: [RequestId: JSONRPCRequest] = [:]
    private var deferredServerRequestOrder: [RequestId] = []
    private var deferredServerRequestBytesById: [RequestId: Int] = [:]
    private var deferredServerRequestTotalBytes = 0
    private var deferredServerRequestCountsByOwner: [ServerRequestOwner: Int] = [:]
    /// 多播：每个 notifications() 调用方拿到**独立**的 AsyncStream，actor 内部维护其
    /// continuation；收到一条通知 yield 给所有订阅者。修复「单消费者流被三处抢占、
    /// 事件被瓜分」导致的对话流滞后 bug。serverRequests 同理多播。
    private struct NotificationSubscriber {
        let methods: Set<String>?
        let threadId: String?
        let continuation: AsyncStream<JSONRPCNotification>.Continuation

        func matches(_ notification: JSONRPCNotification) -> Bool {
            if let methods, !methods.contains(notification.method) { return false }
            guard let threadId else { return true }
            guard let params = notification.params?.value as? [String: Any] else { return true }
            let notificationThreadId = params["threadId"] as? String
                ?? (params["thread"] as? [String: Any])?["id"] as? String
            return notificationThreadId == nil || notificationThreadId == threadId
        }
    }
    private var notificationSubscribers: [UUID: NotificationSubscriber] = [:]
    private var serverRequestContinuations: [
        ServerRequestOwner: [UUID: AsyncStream<JSONRPCRequest>.Continuation]
    ] = [:]
    private var streamsFinished = false
    private var streamOverflowRecoveryActive = false
    private var pump: Task<Void, Never>?

    /// 入站活跃回调（流量即活）：handle 成功解码任一入站消息后触发（涵盖 response/error/
    /// notification/server request——全部是经 transport 已验信道到达的明文）。解码失败的行
    /// 不触发。唯一生产挂钩点 = ConnectionStore.doEstablish（转心跳重置 miss 计数）。
    private var onInboundActivity: (@Sendable () -> Void)?

    func setInboundActivityHandler(_ handler: @escaping @Sendable () -> Void) {
        onInboundActivity = handler
    }

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()

    init(transport: MessageTransport,
         deferredRequestLimits: DeferredServerRequestLimits = .init(),
         streamLimits: JSONRPCStreamLimits = .init()) {
        self.transport = transport
        self.deferredRequestLimits = deferredRequestLimits
        self.streamLimits = streamLimits
    }

    /// 对外通知流（item/turn/thread 等 server notification）。
    /// 多播：每个调用方独立订阅，收到的事件互不抢占（对话归约 / 断线探测各拿一份）。
    func notifications(methods: Set<String>? = nil,
                       threadId: String? = nil) -> AsyncStream<JSONRPCNotification> {
        // transport 已关闭：返回一个立即结束的空流，避免新订阅者永久挂起。
        if streamsFinished { return AsyncStream { $0.finish() } }
        let id = UUID()
        // 通知包含 turn/completed、审批 resolved 等不可重建的控制事件，不能复用交互请求的
        // 24 条保留上限。消费者都必须看到完整有序流；需要压缩时只能在明确可合并的 delta 层做。
        return AsyncStream(bufferingPolicy: .bufferingOldest(streamLimits.notificationBufferCount)) { cont in
            notificationSubscribers[id] = NotificationSubscriber(
                methods: methods,
                threadId: threadId,
                continuation: cont
            )
            cont.onTermination = { [weak self] _ in
                Task { await self?.removeNotifContinuation(id) }
            }
        }
    }

    /// 每类延迟请求有独立 owner 流；新订阅者会收到该 owner 尚未完成的请求。
    func serverRequests(for owner: ServerRequestOwner = .approval) -> AsyncStream<JSONRPCRequest> {
        if streamsFinished { return AsyncStream { $0.finish() } }
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingOldest(streamLimits.serverRequestBufferCount)) { cont in
            serverRequestContinuations[owner, default: [:]][id] = cont
            for requestId in deferredServerRequestOrder {
                guard case .owned(let requestOwner) = deferredServerRequests[requestId],
                      requestOwner == owner,
                      let request = deferredServerRequestPayloads[requestId]
                else { continue }
                if case .dropped = cont.yield(request) {
                    Task { await self.recoverFromStreamOverflow() }
                    break
                }
            }
            cont.onTermination = { [weak self] _ in
                Task { await self?.removeServerRequestContinuation(id, owner: owner) }
            }
        }
    }

#if DEBUG
    /// 测试支持：当前存活的 notifications() 订阅数。用于回归锁「切对话不累积正文订阅」（D2）。
    func liveNotificationSubscriberCount() -> Int { notificationSubscribers.count }
    func deferredServerRequestCount() -> Int { deferredServerRequests.count }
    func deferredServerRequestBytes() -> Int { deferredServerRequestTotalBytes }
#endif

    private func removeNotifContinuation(_ id: UUID) { notificationSubscribers[id] = nil }
    private func removeServerRequestContinuation(_ id: UUID, owner: ServerRequestOwner) {
        serverRequestContinuations[owner]?[id] = nil
        if serverRequestContinuations[owner]?.isEmpty == true {
            serverRequestContinuations[owner] = nil
        }
    }

    func start() {
        guard pump == nil else { return }
        pump = Task { [weak self] in
            guard let self else { return }
            let stream = await self.transport.incoming()
            do {
                for try await line in stream {
                    await self.handle(line)
                }
                await self.failAllPending(TransportError.channelClosed(reason: nil))
            } catch {
                await self.failAllPending(error)
            }
            // 底层 transport 流结束/出错即连接关闭：终结对外的通知与 server-request 流，
            // 让上层（ConnectionStore）能据此感知断线并触发重连。
            await self.finishStreams()
        }
    }

    private func finishStreams() {
        streamsFinished = true
        clearDeferredServerRequests()
        for subscriber in notificationSubscribers.values { subscriber.continuation.finish() }
        notificationSubscribers.removeAll()
        for ownerContinuations in serverRequestContinuations.values {
            for c in ownerContinuations.values { c.finish() }
        }
        serverRequestContinuations.removeAll()
    }

    func stop() {
        pump?.cancel()
        pump = nil
        finishStreams()
    }

    /// Abort the underlying channel when a request-level timeout proves the connection
    /// half-open. The transport's incoming stream spans physical reconnects, so the pump
    /// and its subscribers must remain alive for the recovered channel.
    func abortConnection() async {
        failAllPending(TransportError.channelClosed(reason: "request timed out"))
        await transport.triggerReconnect()
    }

    /// 发起一个请求并挂起等待匹配 id 的响应；error 响应抛出。
    /// 包 `withTaskCancellationHandler`：取消时原子取出并移除该 id 的 pending，以
    /// `CancellationError` resume（同构 failPending，不改按 id 分发）。半开连接（response
    /// 永不到）下，上层取消即可解挂，不再永久挂起——心跳探针的超时/取消得以真正生效（#10）。
    func send(method: String, params: AnyCodable?) async throws -> AnyCodable {
        let id = RequestIdGenerator.next()
        let req = JSONRPCRequest(id: id, method: method, params: params)
        let text = String(data: try encoder.encode(req), encoding: .utf8)!
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<AnyCodable, Error>) in
                pending[id] = cont
                Task {
                    do { try await transport.send(text) }
                    catch { await self.failPending(id, error) }
                }
            }
        } onCancel: {
            Task { await self.failPending(id, CancellationError()) }
        }
    }

    /// 发送带 request id 的命令，但不保留 pending continuation 等待响应。
    /// 用于 interrupt 这类离开页面前必须写入 transport、又不能被半开连接阻塞的操作。
    func sendWithoutWaiting(method: String, params: AnyCodable?) async throws {
        let req = JSONRPCRequest(id: RequestIdGenerator.next(), method: method, params: params)
        let text = String(data: try encoder.encode(req), encoding: .utf8)!
        try await transport.send(text)
    }

    /// 发送 notification（如 initialized）。
    func notify(method: String, params: AnyCodable?) async throws {
        let n = JSONRPCNotification(method: method, params: params)
        let text = String(data: try encoder.encode(n), encoding: .utf8)!
        try await transport.send(text)
    }

    /// 回 server→client 请求一个 response。
    @discardableResult
    func respond(to id: RequestId, result: AnyCodable) async throws -> Bool {
        let resp = JSONRPCResponse(id: id, result: result)
        let text = String(data: try encoder.encode(resp), encoding: .utf8)!
        return try await completeDeferredServerRequest(id, text: text)
    }

    @discardableResult
    func respond(to id: RequestId, error: JSONRPCErrorBody) async throws -> Bool {
        let resp = JSONRPCError(id: id, error: error)
        let text = String(data: try encoder.encode(resp), encoding: .utf8)!
        return try await completeDeferredServerRequest(id, text: text)
    }

    private func completeDeferredServerRequest(_ id: RequestId, text: String) async throws -> Bool {
        guard case .owned(let owner) = deferredServerRequests[id] else { return false }
        deferredServerRequests[id] = .completing(owner)
        do {
            try await transport.send(text)
            if case .completing = deferredServerRequests[id] {
                removeDeferredServerRequest(id)
            }
            return true
        } catch {
            if !streamsFinished, case .completing = deferredServerRequests[id] {
                deferredServerRequests[id] = .owned(owner)
            }
            throw error
        }
    }

    /// `serverRequest/resolved` 表示另一客户端已完成该 request；撤销本端 owner，禁止迟到响应。
    func discardServerRequest(_ id: RequestId) {
        removeDeferredServerRequest(id)
    }

    // MARK: - 分发

    private func handle(_ line: String) async {
        guard let data = line.data(using: .utf8),
              let msg = try? JSONDecoder().decode(JSONRPCMessage.self, from: data) else { return }
        onInboundActivity?()   // 流量即活：任何成功解码的入站消息都是存活证据
        switch msg {
        // response/error 按 id 精确匹配 pending 表唤醒发起者；查无此 id 则 removeValue 返回 nil、静默丢弃。
        // 保留依据（spike 2026-06-24 实测坐实，§6.2）：官方 ws response 点对点按 id 回发起连接，
        // iPad 本就只收到自己 id 的 response，「按 id 精确匹配、未匹配则丢弃」是裸 JSON-RPC 下
        // 天然正确的分发机制（非为去串台而加的特殊逻辑），无需改动。
        case .response(let r):
            pending.removeValue(forKey: r.id)?.resume(returning: r.result)
        case .error(let e):
            pending.removeValue(forKey: e.id)?
                .resume(throwing: TransportError.proxyFailed(e.error.message))
        case .notification(let n):
            for subscriber in notificationSubscribers.values where subscriber.matches(n) {
                if case .dropped = subscriber.continuation.yield(n) {
                    await recoverFromStreamOverflow()
                    break
                }
            }
        case .request(let req):
            guard deferredServerRequests[req.id] == nil else { return }
            switch ServerRequestRouter.outcome(for: req.method) {
            case .deferred(let owner):
                guard canRetainDeferredRequest(owner: owner, payloadBytes: data.count) else {
                    try? await respondWithError(
                        to: req.id,
                        code: -32000,
                        message: "Server busy: too many pending interactive requests"
                    )
                    return
                }
                deferredServerRequests[req.id] = .owned(owner)
                deferredServerRequestPayloads[req.id] = req
                deferredServerRequestOrder.append(req.id)
                deferredServerRequestBytesById[req.id] = data.count
                deferredServerRequestTotalBytes += data.count
                deferredServerRequestCountsByOwner[owner, default: 0] += 1
                if let continuations = serverRequestContinuations[owner] {
                    for c in continuations.values {
                        if case .dropped = c.yield(req) {
                            await recoverFromStreamOverflow()
                            break
                        }
                    }
                }
            case .methodNotSupported:
                try? await respondWithError(
                    to: req.id,
                    code: -32601,
                    message: "Method not found: \(req.method)"
                )
            }
        }
    }

    private func respondWithError(to id: RequestId, code: Int, message: String) async throws {
        let response = JSONRPCError(id: id, error: JSONRPCErrorBody(code: code, message: message))
        let text = String(data: try encoder.encode(response), encoding: .utf8)!
        try await transport.send(text)
    }

    private func canRetainDeferredRequest(owner: ServerRequestOwner, payloadBytes: Int) -> Bool {
        guard deferredServerRequests.count < deferredRequestLimits.maximumTotalCount,
              deferredServerRequestCountsByOwner[owner, default: 0]
                < deferredRequestLimits.maximumPerOwnerCount,
              payloadBytes <= deferredRequestLimits.maximumTotalBytes - deferredServerRequestTotalBytes
        else { return false }
        return true
    }

    private func removeDeferredServerRequest(_ id: RequestId) {
        guard let state = deferredServerRequests[id] else { return }
        let owner: ServerRequestOwner
        switch state {
        case .owned(let value), .completing(let value): owner = value
        }
        deferredServerRequests[id] = nil
        deferredServerRequestPayloads[id] = nil
        deferredServerRequestOrder.removeAll { $0 == id }
        deferredServerRequestTotalBytes -= deferredServerRequestBytesById.removeValue(forKey: id) ?? 0
        let remaining = max(0, deferredServerRequestCountsByOwner[owner, default: 0] - 1)
        deferredServerRequestCountsByOwner[owner] = remaining == 0 ? nil : remaining
    }

    private func clearDeferredServerRequests() {
        deferredServerRequests.removeAll()
        deferredServerRequestPayloads.removeAll()
        deferredServerRequestOrder.removeAll()
        deferredServerRequestBytesById.removeAll()
        deferredServerRequestTotalBytes = 0
        deferredServerRequestCountsByOwner.removeAll()
    }

    private func failPending(_ id: RequestId, _ error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func failAllPending(_ error: Error) {
        for (_, cont) in pending { cont.resume(throwing: error) }
        pending.removeAll()
    }

    private func recoverFromStreamOverflow() async {
        guard !streamOverflowRecoveryActive, !streamsFinished else { return }
        streamOverflowRecoveryActive = true
        let error = TransportError.inboundBufferOverflow(
            limit: max(streamLimits.notificationBufferCount, streamLimits.serverRequestBufferCount)
        )
        failAllPending(error)
        await transport.triggerReconnect()
    }

    /// 失败所有在途请求（物理断线时由上层调用）。incoming() 流跨重连不结束，
    /// 故 start() 的「流结束才 failAllPending」覆盖不到物理断线；断线瞬间已发出、
    /// 等响应的请求若不在此失败将永久挂起（响应不会在新通道重放）。调用方据此重试。
    /// 同时失效所有 server→client 延迟请求的响应所有权；这些请求只能由服务端在新连接重发，
    /// 旧 request id 不得在新物理连接上被补发或重复完成。
    func failInflight(_ error: Error) {
        streamOverflowRecoveryActive = false
        failAllPending(error)
        clearDeferredServerRequests()
    }
}
