import Foundation
import Observation
import os

private let connLog = Logger(subsystem: "com.tangyujie.codexremote", category: "connection")

/// 连接超时错误（SSH/握手在限定时间内未完成）。
struct ConnectionTimeoutError: LocalizedError {
    var errorDescription: String? { "连接超时（SSH 或握手在 20 秒内未完成）" }
}

/// 连接配置（host + SSH 端口 + 鉴权）。`.stub` 供测试使用。
struct ConnectionConfig: Sendable {
    var host: String
    var sshPort: Int
    var auth: SSHAuth

    static var stub: ConnectionConfig {
        .init(host: "x", sshPort: 22, auth: .password(user: "u", password: "p"))
    }
}

/// 连接生命周期状态机（设计 §7）。
enum ConnectionPhase: Equatable {
    case disconnected
    case sshConnecting
    case execProxy
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

/// 连接状态层：驱动 SSH→exec proxy→JSON-RPC initialize 握手，监听断线并指数退避重连。
///
/// `transportFactory` 注入便于测试 mock：生产环境传 `liveTransportFactory`
/// （内部走 SSH + `codex app-server --listen stdio://` exec），测试传返回 MockTransport 的闭包。
@Observable
@MainActor
final class ConnectionStore {
    private(set) var phase: ConnectionPhase = .disconnected
    private(set) var serverInfo: InitializeResponse?
    var rpc: JSONRPCClient?

    private let transportFactory: @Sendable (ConnectionConfig) async throws -> MessageTransport
    private var config: ConnectionConfig?
    private var reconnectAttempts = 0
    private var disconnectObserver: Task<Void, Never>?
    /// 当前连接尝试序号：每次新连接 +1；超时也 +1 以作废仍在后台跑的旧 establish。
    private var activeAttempt = 0

    init(transportFactory: @escaping @Sendable (ConnectionConfig) async throws -> MessageTransport) {
        self.transportFactory = transportFactory
    }

    /// 发起连接（fire-and-forget，结果经 `phase` 反映给 UI）。
    /// 新连接立即把 phase 置为 execProxy → 自动清除上一次的 .failed 错误。
    /// 含 20s 硬超时：SSH/握手卡住时强制转 .failed 并作废后台残留任务（不依赖 Task 取消，
    /// 因为底层 Citadel/NIO 不一定响应取消）。
    func connect(config: ConnectionConfig) {
        self.config = config
        reconnectAttempts = 0
        activeAttempt += 1
        let attempt = activeAttempt
        phase = .execProxy
        connLog.info("connect 开始 host=\(config.host, privacy: .public):\(config.sshPort) attempt=\(attempt)")

        // 建连 + 握手任务。仅当仍是当前 attempt 时才落地 phase。
        Task { [weak self] in
            guard let self else { return }
            do {
                let client = try await self.doEstablish(config)
                guard attempt == self.activeAttempt else { await client.stop(); return }
                self.rpc = client
                self.phase = .ready
                self.reconnectAttempts = 0
                self.observeDisconnect(client)
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

    /// 主动断开（停止重连观察 + 关闭 RPC）。
    func disconnect() async {
        activeAttempt += 1                // 作废任何在途连接
        disconnectObserver?.cancel()
        disconnectObserver = nil
        if let rpc { await rpc.stop() }
        rpc = nil
        phase = .disconnected
    }

    // MARK: - 握手

    /// 建 SSH + exec app-server + initialize 握手，返回就绪的 JSON-RPC client。
    /// 不直接落 phase=.ready（由调用方按 attempt token 判定后落地）。
    private func doEstablish(_ config: ConnectionConfig) async throws -> JSONRPCClient {
        phase = .execProxy
        connLog.notice("doEstablish: 开始建 SSH + exec app-server…")
        let transport = try await transportFactory(config)
        connLog.notice("doEstablish: SSH+exec 就绪, 启动 JSONRPCClient")
        let client = JSONRPCClient(transport: transport)
        await client.start()

        phase = .initializing
        connLog.notice("doEstablish: 发送 initialize, 等响应…")
        let params = InitializeParams(
            clientInfo: ClientInfo(name: "CodexRemote", title: nil, version: "0.1.0"),
            capabilities: nil)
        let result = try await client.send(method: RPCMethod.initialize,
                                           params: try Self.encode(params))
        serverInfo = try Self.decode(InitializeResponse.self, from: result)
        connLog.notice("doEstablish: 收到 initialize 响应, 发 initialized")
        try await client.notify(method: RPCMethod.initialized, params: nil)
        connLog.notice("doEstablish: 握手完成")
        return client
    }

    // MARK: - 断线观察 + 重连

    private func observeDisconnect(_ client: JSONRPCClient) {
        disconnectObserver?.cancel()
        disconnectObserver = Task { [weak self] in
            // 通知流结束（transport 关闭/出错）即视为断线。
            for await _ in await client.notifications() { }
            guard let self, !Task.isCancelled else { return }
            guard let config = self.config else { return }
            self.phase = .reconnecting
            await self.reconnectWithBackoff(config)
        }
    }

    private func reconnectWithBackoff(_ config: ConnectionConfig) async {
        guard !Task.isCancelled else { return }
        reconnectAttempts += 1
        let delay = min(pow(2.0, Double(reconnectAttempts)), 30)   // 指数退避，封顶 30s
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        guard !Task.isCancelled else { return }
        do {
            let client = try await doEstablish(config)   // 重新 initialize
            rpc = client
            phase = .ready
            reconnectAttempts = 0
            observeDisconnect(client)
        } catch {
            phase = .reconnecting
            await reconnectWithBackoff(config)
        }
    }

    /// 把底层错误转为面向用户的可读文案。
    static func friendlyMessage(_ error: Error) -> String {
        if let t = error as? TransportError {
            switch t {
            case .sshAuthFailed(let m):
                return String(localized: "conn.error.authFailed \(m)")   // 单行：SSH 鉴权失败：%@
            case .appServerUnreachable:
                return "已连上 SSH 但 app-server 不可达，请确认 Mac 上 codex 可用。"
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
