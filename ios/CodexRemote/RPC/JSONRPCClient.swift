import Foundation

/// JSON-RPC 客户端（actor）：消费 transport.incoming()，对每条 JSON 文本解码为
/// JSONRPCMessage 并分发：
///   - .response/.error → 按 id 唤醒等待中的 send(method:params:)（pending 表）
///   - .notification → yield 到对外通知流
///   - .request（server→client，审批等）→ 交给 server-request 处理器并回 response
actor JSONRPCClient {
    typealias ServerRequestHandler = @Sendable (JSONRPCRequest) async -> AnyCodable

    private let transport: MessageTransport
    private var nextId: Int64 = 0
    private var pending: [RequestId: CheckedContinuation<AnyCodable, Error>] = [:]
    private var serverRequestHandler: ServerRequestHandler?
    private let notifStream: AsyncStream<JSONRPCNotification>
    private let notifContinuation: AsyncStream<JSONRPCNotification>.Continuation
    private let serverRequestStream: AsyncStream<JSONRPCRequest>
    private let serverRequestContinuation: AsyncStream<JSONRPCRequest>.Continuation
    private var pump: Task<Void, Never>?

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()

    init(transport: MessageTransport) {
        self.transport = transport
        var nc: AsyncStream<JSONRPCNotification>.Continuation!
        notifStream = AsyncStream(bufferingPolicy: .unbounded) { nc = $0 }
        notifContinuation = nc
        var sc: AsyncStream<JSONRPCRequest>.Continuation!
        serverRequestStream = AsyncStream(bufferingPolicy: .unbounded) { sc = $0 }
        serverRequestContinuation = sc
    }

    /// 对外通知流（item/turn/thread 等 server notification）。
    func notifications() -> AsyncStream<JSONRPCNotification> { notifStream }

    /// 对外 server-request 流（供审批层在没有同步 handler 时观察）。
    func serverRequests() -> AsyncStream<JSONRPCRequest> { serverRequestStream }

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
        notifContinuation.finish()
        serverRequestContinuation.finish()
    }

    func stop() {
        pump?.cancel()
        pump = nil
        notifContinuation.finish()
        serverRequestContinuation.finish()
    }

    /// 发起一个请求并挂起等待匹配 id 的响应；error 响应抛出。
    func send(method: String, params: AnyCodable?) async throws -> AnyCodable {
        nextId += 1
        let id = RequestId.int(nextId)
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
        case .response(let r):
            pending.removeValue(forKey: r.id)?.resume(returning: r.result)
        case .error(let e):
            pending.removeValue(forKey: e.id)?
                .resume(throwing: TransportError.proxyFailed(e.error.message))
        case .notification(let n):
            notifContinuation.yield(n)
        case .request(let req):
            serverRequestContinuation.yield(req)
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
