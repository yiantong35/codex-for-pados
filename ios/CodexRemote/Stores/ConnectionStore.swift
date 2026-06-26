import Foundation
import Observation
import os

private let connLog = Logger(subsystem: "com.tangyujie.codexremote", category: "connection")

/// 连接超时错误（建连/握手在限定时间内未完成）。
struct ConnectionTimeoutError: LocalizedError {
    var errorDescription: String? { "连接超时（连接或握手在 20 秒内未完成）" }
}

/// 连接配置（ws endpoint + token）。`.stub` 供测试使用。
struct ConnectionConfig: Sendable {
    var host: String
    var port: Int
    var token: String

    /// 组装 ws URL：ws://host:port/
    /// token 改走 ws 握手的 Authorization: Bearer header（不进 query），避免日志/历史泄漏。
    var wsURL: URL {
        var comps = URLComponents()
        comps.scheme = "ws"
        comps.host = host
        comps.port = port
        comps.path = "/"
        return comps.url!
    }

    static var stub: ConnectionConfig {
        .init(host: "x", port: 8799, token: "t")
    }
}

/// 连接生命周期状态机（设计 §7）。
enum ConnectionPhase: Equatable {
    case disconnected
    case connecting
    case initializing
    case ready
    case reconnecting
    case failed(String)

    /// 是否已是终态（成功或失败）——用于超时判定：未终态才触发超时失败。
    var isSettled: Bool {
        switch self {
        case .ready, .failed: return true
        default: return false
        }
    }
}

/// 连接状态层：驱动 ws 连接 → JSON-RPC initialize 握手，
/// 订阅 transport 控制信号驱动 UI 重连指示与会话 resume。ws 物理抖动由 WSTransport 内部自吞。
///
/// initialize 语义（spike 2026-06-24 实测坐实）：官方 ws app-server 的 initialize 是**连接级**
/// （per-connection）——每个 ws 连接各自发 initialize 并各自成功返回 InitializeResponse，互不影响，
/// 不存在「进程级单次」语义，自己的连接绝不会拿 -32600 Already initialized。故无「Already initialized
/// 容忍」逻辑：initialize 失败即握手失败，正常落 .failed。
///
/// `transportFactory` 注入便于测试 mock：生产环境传 `liveTransportFactory`
/// （构造连官方 app-server 的 WSTransport），测试传返回 MockTransport 的闭包。
@Observable
@MainActor
final class ConnectionStore {
    private(set) var phase: ConnectionPhase = .disconnected
    private(set) var serverInfo: InitializeResponse?
    var rpc: JSONRPCClient?

    private let transportFactory: @Sendable (ConnectionConfig) async throws -> MessageTransport
    private var config: ConnectionConfig?
    private var transport: MessageTransport?
    private var resumeHandler: (@Sendable () async -> Void)?
    private var controlObserver: Task<Void, Never>?
    /// 本次连接是否已触发过「首连恢复」（rejoinRunningThreads），保证恰好一次。
    /// 每次新 connect()/disconnect() 重置。物理重连走 observeControl 的 .ready，与此独立。
    private var didInitialRejoin = false
    /// 当前连接是否已就绪（phase=.ready），用于在 handler 晚于 .ready 注册时补触发首连恢复。
    private var isReady = false
    /// 当前连接尝试序号：每次新连接 +1；超时也 +1 以作废仍在后台跑的旧 establish。
    private var activeAttempt = 0

    init(transportFactory: @escaping @Sendable (ConnectionConfig) async throws -> MessageTransport) {
        self.transportFactory = transportFactory
    }

    /// 注入「重连后会话恢复」的回调（§5 接 thread/loaded/list + resume）。
    /// 真实接线中 ConversationView 在 rpc 就绪后才注册，可能晚于首连 .ready——
    /// 故注册时若连接已就绪且尚未做过首连恢复，立即补触发一次（对齐「连上自动订阅全部活跃 thread」）。
    func setResumeHandler(_ h: @escaping @Sendable () async -> Void) {
        resumeHandler = h
        triggerInitialRejoinIfReady()
    }

    /// 首连恢复触发器：当「已就绪」且「handler 已注册」且「本次连接尚未做过首连恢复」三者满足时，
    /// 触发恰好一次 resumeHandler。connect 落 .ready 与 setResumeHandler 谁后到都能触发，且不重复。
    /// 物理重连的恢复由 observeControl 的 .ready 分支独立负责，不经此处。
    private func triggerInitialRejoinIfReady() {
        guard isReady, !didInitialRejoin, let h = resumeHandler else { return }
        didInitialRejoin = true
        Task { await h() }
    }

    /// 发起连接（fire-and-forget，结果经 `phase` 反映给 UI）。
    /// 新连接立即把 phase 置为 connecting → 自动清除上一次的 .failed 错误。
    /// 含 20s 硬超时：建连/握手卡住时强制转 .failed 并作废后台残留任务。
    func connect(config: ConnectionConfig) {
        guard !config.token.isEmpty else {
            connLog.error("connect 拒绝：token 为空")
            phase = .failed("请先在设置中配置 token")
            return
        }
        self.config = config
        activeAttempt += 1
        let attempt = activeAttempt
        phase = .connecting
        // 新连接：重置首连恢复状态（上一次连接的 rejoin 不应抑制本次）。
        didInitialRejoin = false
        isReady = false
        connLog.info("connect 开始 host=\(config.host, privacy: .public):\(config.port) attempt=\(attempt)")

        // 建连 + 握手任务。仅当仍是当前 attempt 时才落地 phase。
        Task { [weak self] in
            guard let self else { return }
            do {
                let (client, newTransport) = try await self.doEstablish(config)
                guard attempt == self.activeAttempt else {
                    // 本 attempt 已被超时/新连接作废：关掉自己建的 client + transport，
                    // 否则其 WSTransport.pumpTask/ws task 泄漏并继续自动重连一个已丢弃的连接（H2）。
                    await client.stop()
                    await newTransport.close()
                    return
                }
                self.rpc = client
                self.transport = newTransport
                self.phase = .ready
                self.isReady = true
                self.observeControl(newTransport)
                // 首连成功也触发一次会话恢复（rejoin），对齐「连上自动订阅全部活跃 thread」。
                // handler 可能尚未注册（ConversationView 在 rpc 就绪后才 setResumeHandler）：
                // 那种情况下由 setResumeHandler 注册时补触发，二者谁后到都只触发一次。
                self.triggerInitialRejoinIfReady()
                connLog.info("connect 成功 phase=ready")
            } catch {
                guard attempt == self.activeAttempt else { return }   // 已被超时/新尝试作废
                connLog.error("connect 失败: \(String(describing: error), privacy: .public)")
                self.phase = .failed(Self.friendlyMessage(error))
            }
        }

        // 硬超时：到点若仍未 settle，强制失败并作废本次 attempt。
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard let self, attempt == self.activeAttempt, !self.phase.isSettled else { return }
            connLog.error("connect 超时 attempt=\(attempt)")
            self.phase = .failed(ConnectionTimeoutError().errorDescription ?? "连接超时")
            self.activeAttempt += 1   // 作废仍在后台跑的 establish（其完成时 token 不匹配 → 忽略）
        }
    }

    /// 主动断开（停止控制信号观察 + 关闭 RPC + 关闭底层 transport）。
    func disconnect() async {
        activeAttempt += 1                // 作废任何在途连接
        controlObserver?.cancel()
        controlObserver = nil
        if let rpc { await rpc.stop() }
        rpc = nil
        // 关闭底层 transport：否则 WSTransport.pumpTask + URLSession ws task 泄漏，
        // 断线后还会自动重连一个 UI 已丢弃的连接并继续 yield（H2）。须在置 nil 前 close。
        if let transport { await transport.close() }
        transport = nil
        isReady = false
        didInitialRejoin = false
        phase = .disconnected
    }

    // MARK: - 握手

    /// 建 ws transport + initialize 握手，返回就绪的 JSON-RPC client 及其 transport。
    /// initialize 是连接级（spike 实测）：本连接发 initialize 期待自己的 InitializeResponse，
    /// 失败即握手失败（向上抛出，由 connect 落 .failed），不做任何 -32600 特殊容忍。
    /// 不直接落 phase=.ready，也不写 self.transport（由调用方按 attempt token 判定后落地，
    /// 避免被作废的 attempt 污染 self.transport / 泄漏 transport，H2）。
    private func doEstablish(_ config: ConnectionConfig) async throws -> (JSONRPCClient, MessageTransport) {
        phase = .connecting
        connLog.notice("doEstablish: 开始建 ws transport…")
        let transport = try await transportFactory(config)
        connLog.notice("doEstablish: transport 就绪, 启动 JSONRPCClient")
        let client = JSONRPCClient(transport: transport)
        await client.start()

        phase = .initializing
        connLog.notice("doEstablish: 发送 initialize, 等响应…")
        let params = InitializeParams(
            clientInfo: ClientInfo(name: "CodexRemote", title: nil, version: "0.1.0"),
            capabilities: nil)
        // 连接级 initialize：失败直接抛出（不容忍 -32600），由 connect 落 .failed。
        let result = try await client.send(method: RPCMethod.initialize,
                                           params: try Self.encode(params))
        serverInfo = try? Self.decode(InitializeResponse.self, from: result)
        try? await client.notify(method: RPCMethod.initialized, params: nil)
        connLog.notice("doEstablish: 握手完成")
        return (client, transport)
    }

    // MARK: - 控制信号观察

    /// 订阅 transport 控制信号：reconnecting/ready 驱动 UI 重连指示。
    /// ws 物理抖动的重连由 WSTransport 内部负责（incoming 流跨重连不结束），此处不再重新 initialize。
    /// 去 envelope 后无 snapshotNeeded；重连成功（.ready）后经 resumeHandler 触发会话恢复
    /// （§5：thread/loaded/list + thread/resume rejoin）。
    /// 注意：首连成功走 connect 里直接落 .ready（不经此处），其首连恢复由 connect 落 .ready /
    /// setResumeHandler 经 triggerInitialRejoinIfReady 触发（恰好一次）；此处的 .ready 仅来自
    /// WSTransport 物理重连，故 rejoin 在「首连一次 + 每次物理重连各一次」触发，不重复。
    private func observeControl(_ transport: MessageTransport) {
        controlObserver?.cancel()
        controlObserver = Task { [weak self] in
            for await ev in transport.control() {
                guard let self else { return }
                switch ev {
                case .reconnecting:
                    self.phase = .reconnecting
                    // 物理断线：失败断线瞬间已发出、仍等响应的在途请求，避免其永久挂起（H1）。
                    // 响应不会在新通道重放；失败后调用方/UI 可重试。control() 单消费者由本处独占，
                    // 故由 ConnectionStore（同时持 rpc 与控制流）触发，而非让 JSONRPCClient 抢消费控制流。
                    if let rpc = self.rpc {
                        Task { await rpc.failInflight(TransportError.channelClosed(reason: "reconnecting")) }
                    }
                case .ready:
                    self.phase = .ready
                    if let h = self.resumeHandler { await h() }   // 重连成功 → 经官方列表恢复并重新订阅
                }
            }
        }
    }

    /// 把底层错误转为面向用户的可读文案。
    static func friendlyMessage(_ error: Error) -> String {
        if let t = error as? TransportError {
            switch t {
            case .proxyFailed(let m):  return "通道建立失败：\(m)"
            case .channelClosed(let r): return "连接通道关闭：\(r ?? "未知原因")"
            case .notConnected:        return "未连接"
            // TODO(T2.4): 替换为 sshAuthFailed/handshakeFailed 的正式中文文案
            default:                    return error.localizedDescription
            }
        }
        if let to = error as? ConnectionTimeoutError { return to.errorDescription ?? "连接超时" }
        return error.localizedDescription
    }

    // MARK: - AnyCodable 编解码桥

    private static func encode<T: Encodable>(_ v: T) throws -> AnyCodable {
        let data = try JSONEncoder().encode(v)
        return try JSONDecoder().decode(AnyCodable.self, from: data)
    }

    private static func decode<T: Decodable>(_ t: T.Type, from a: AnyCodable) throws -> T {
        let data = try JSONEncoder().encode(a)
        return try JSONDecoder().decode(t, from: data)
    }
}
