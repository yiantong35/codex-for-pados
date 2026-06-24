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

    /// 组装带 token 的 ws URL：ws://host:port/?token=<token>
    var wsURL: URL {
        var comps = URLComponents()
        comps.scheme = "ws"
        comps.host = host
        comps.port = port
        comps.path = "/"
        comps.queryItems = [URLQueryItem(name: "token", value: token)]
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

/// 连接状态层：驱动 ws 连接 → JSON-RPC initialize 握手（容忍 Already initialized），
/// 订阅 transport 控制信号驱动 UI 重连指示与会话 resume。ws 物理抖动由 WSTransport 内部自吞。
///
/// `transportFactory` 注入便于测试 mock：生产环境传 `liveTransportFactory`
/// （构造连 daemon 的 WSTransport），测试传返回 MockTransport 的闭包。
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
    /// 当前连接尝试序号：每次新连接 +1；超时也 +1 以作废仍在后台跑的旧 establish。
    private var activeAttempt = 0

    init(transportFactory: @escaping @Sendable (ConnectionConfig) async throws -> MessageTransport) {
        self.transportFactory = transportFactory
    }

    /// 注入「重连后会话恢复」的回调（§5 接 thread/loaded/list + resume；目前保留为通用钩子）。
    func setResumeHandler(_ h: @escaping @Sendable () async -> Void) { resumeHandler = h }

    /// 发起连接（fire-and-forget，结果经 `phase` 反映给 UI）。
    /// 新连接立即把 phase 置为 connecting → 自动清除上一次的 .failed 错误。
    /// 含 20s 硬超时：建连/握手卡住时强制转 .failed 并作废后台残留任务。
    func connect(config: ConnectionConfig) {
        self.config = config
        activeAttempt += 1
        let attempt = activeAttempt
        phase = .connecting
        connLog.info("connect 开始 host=\(config.host, privacy: .public):\(config.port) attempt=\(attempt)")

        // 建连 + 握手任务。仅当仍是当前 attempt 时才落地 phase。
        Task { [weak self] in
            guard let self else { return }
            do {
                let client = try await self.doEstablish(config)
                guard attempt == self.activeAttempt else { await client.stop(); return }
                self.rpc = client
                self.phase = .ready
                if let transport = self.transport { self.observeControl(transport) }
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

    /// 主动断开（停止控制信号观察 + 关闭 RPC）。
    func disconnect() async {
        activeAttempt += 1                // 作废任何在途连接
        controlObserver?.cancel()
        controlObserver = nil
        if let rpc { await rpc.stop() }
        rpc = nil
        transport = nil
        phase = .disconnected
    }

    // MARK: - 握手

    /// 建 ws transport + initialize 握手，返回就绪的 JSON-RPC client。
    /// 容忍式 initialize：收到自己 id 的 -32600 Already initialized 也视为握手成功（设计 §4 A3）。
    /// 不直接落 phase=.ready（由调用方按 attempt token 判定后落地）。
    private func doEstablish(_ config: ConnectionConfig) async throws -> JSONRPCClient {
        phase = .connecting
        connLog.notice("doEstablish: 开始建 ws transport…")
        let transport = try await transportFactory(config)
        self.transport = transport
        connLog.notice("doEstablish: transport 就绪, 启动 JSONRPCClient")
        let client = JSONRPCClient(transport: transport)
        await client.start()

        phase = .initializing
        connLog.notice("doEstablish: 发送 initialize, 等响应…")
        let params = InitializeParams(
            clientInfo: ClientInfo(name: "CodexRemote", title: nil, version: "0.1.0"),
            capabilities: nil)
        do {
            let result = try await client.send(method: RPCMethod.initialize,
                                               params: try Self.encode(params))
            serverInfo = try? Self.decode(InitializeResponse.self, from: result)
            try? await client.notify(method: RPCMethod.initialized, params: nil)  // 仅首个初始化者
            connLog.notice("doEstablish: 握手完成")
        } catch let TransportError.proxyFailed(msg) where msg.contains("Already initialized") {
            connLog.notice("doEstablish: app-server 已被别端初始化，视为握手成功")
            // 不发 initialized（非首个初始化者）
        }
        return client
    }

    // MARK: - 控制信号观察

    /// 订阅 transport 控制信号：reconnecting/ready 驱动 UI 重连指示。
    /// ws 物理抖动的重连由 WSTransport 内部负责（incoming 流跨重连不结束），此处不再重新 initialize。
    /// 去 envelope 后无 snapshotNeeded；会话恢复（§5）将接到 .ready 后经 thread/loaded/list + resume。
    private func observeControl(_ transport: MessageTransport) {
        controlObserver?.cancel()
        controlObserver = Task { [weak self] in
            for await ev in transport.control() {
                guard let self else { return }
                switch ev {
                case .reconnecting: self.phase = .reconnecting
                case .ready:        self.phase = .ready
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
