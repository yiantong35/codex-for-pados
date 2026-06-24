import Foundation

/// JSON-RPC 客户端（actor）：消费 transport.incoming()，对每条 JSON 文本解码为
/// JSONRPCMessage 并分发：
///   - .response/.error → 按 id 唤醒等待中的 send(method:params:)（pending 表）
///   - .notification → yield 到对外通知流
///   - .request（server→client，审批等）→ 交给 server-request 处理器并回 response
actor JSONRPCClient {
    typealias ServerRequestHandler = @Sendable (JSONRPCRequest) async -> AnyCodable

    private let transport: MessageTransport
    private var pending: [RequestId: CheckedContinuation<AnyCodable, Error>] = [:]
    private var serverRequestHandler: ServerRequestHandler?
    /// 多播：每个 notifications() 调用方拿到**独立**的 AsyncStream，actor 内部维护其
    /// continuation；收到一条通知 yield 给所有订阅者。修复「单消费者流被三处抢占、
    /// 事件被瓜分」导致的对话流滞后 bug。serverRequests 同理多播。
    private var notifContinuations: [UUID: AsyncStream<JSONRPCNotification>.Continuation] = [:]
    private var serverRequestContinuations: [UUID: AsyncStream<JSONRPCRequest>.Continuation] = [:]
    private var streamsFinished = false
    private var pump: Task<Void, Never>?

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()

    init(transport: MessageTransport) {
        self.transport = transport
    }

    /// 对外通知流（item/turn/thread 等 server notification）。
    /// 多播：每个调用方独立订阅，收到的事件互不抢占（对话归约 / 断线探测各拿一份）。
    func notifications() -> AsyncStream<JSONRPCNotification> {
        // transport 已关闭：返回一个立即结束的空流，避免新订阅者永久挂起。
        if streamsFinished { return AsyncStream { $0.finish() } }
        let id = UUID()
        return AsyncStream(bufferingPolicy: .unbounded) { cont in
            notifContinuations[id] = cont
            cont.onTermination = { [weak self] _ in
                Task { await self?.removeNotifContinuation(id) }
            }
        }
    }

    /// 对外 server-request 流（供审批层在没有同步 handler 时观察）。多播，语义同 notifications()。
    func serverRequests() -> AsyncStream<JSONRPCRequest> {
        if streamsFinished { return AsyncStream { $0.finish() } }
        let id = UUID()
        return AsyncStream(bufferingPolicy: .unbounded) { cont in
            serverRequestContinuations[id] = cont
            cont.onTermination = { [weak self] _ in
                Task { await self?.removeServerRequestContinuation(id) }
            }
        }
    }

    private func removeNotifContinuation(_ id: UUID) { notifContinuations[id] = nil }
    private func removeServerRequestContinuation(_ id: UUID) { serverRequestContinuations[id] = nil }

    /// 注册一个同步处理 server→client 请求的回调（返回值会被编码为 response.result 回发）。
    func setServerRequestHandler(_ h: @escaping ServerRequestHandler) { serverRequestHandler = h }

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
        for c in notifContinuations.values { c.finish() }
        notifContinuations.removeAll()
        for c in serverRequestContinuations.values { c.finish() }
        serverRequestContinuations.removeAll()
    }

    func stop() {
        pump?.cancel()
        pump = nil
        finishStreams()
    }

    /// 发起一个请求并挂起等待匹配 id 的响应；error 响应抛出。
    func send(method: String, params: AnyCodable?) async throws -> AnyCodable {
        let id = RequestIdGenerator.next()
        let req = JSONRPCRequest(id: id, method: method, params: params)
        let text = String(data: try encoder.encode(req), encoding: .utf8)!
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<AnyCodable, Error>) in
            pending[id] = cont
            Task {
                do { try await transport.send(text) }
                catch { await self.failPending(id, error) }
            }
        }
    }

    /// 发送 notification（如 initialized）。
    func notify(method: String, params: AnyCodable?) async throws {
        let n = JSONRPCNotification(method: method, params: params)
        let text = String(data: try encoder.encode(n), encoding: .utf8)!
        try await transport.send(text)
    }

    /// 回 server→client 请求一个 response。
    func respond(to id: RequestId, result: AnyCodable) async throws {
        let resp = JSONRPCResponse(id: id, result: result)
        let text = String(data: try encoder.encode(resp), encoding: .utf8)!
        try await transport.send(text)
    }

    // MARK: - 分发

    private func handle(_ line: String) async {
        guard let data = line.data(using: .utf8),
              let msg = try? JSONDecoder().decode(JSONRPCMessage.self, from: data) else { return }
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
            for c in notifContinuations.values { c.yield(n) }
        case .request(let req):
            for c in serverRequestContinuations.values { c.yield(req) }
            if let handler = serverRequestHandler {
                let result = await handler(req)
                try? await respond(to: req.id, result: result)
            }
        }
    }

    private func failPending(_ id: RequestId, _ error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func failAllPending(_ error: Error) {
        for (_, cont) in pending { cont.resume(throwing: error) }
        pending.removeAll()
    }
}
