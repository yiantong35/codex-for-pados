import Foundation
import Observation

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

    init(transportFactory: @escaping @Sendable (ConnectionConfig) async throws -> MessageTransport) {
        self.transportFactory = transportFactory
    }

    /// 建立连接并完成握手。失败时 phase=.failed(原因) 并抛出。
    func connect(config: ConnectionConfig) async throws {
        self.config = config
        reconnectAttempts = 0
        do {
            try await establish(config)
        } catch {
            phase = .failed("\(error)")
            throw error
        }
    }

    /// 主动断开（停止重连观察 + 关闭 RPC）。
    func disconnect() async {
        disconnectObserver?.cancel()
        disconnectObserver = nil
        if let rpc { await rpc.stop() }
        rpc = nil
        phase = .disconnected
    }

    // MARK: - 握手

    private func establish(_ config: ConnectionConfig) async throws {
        // 工厂内部含 SSH 建连 + exec codex app-server proxy；这里统一标记为 execProxy。
        phase = .execProxy
        let transport = try await transportFactory(config)
        let client = JSONRPCClient(transport: transport)
        await client.start()
        rpc = client

        phase = .initializing
        let params = InitializeParams(
            clientInfo: ClientInfo(name: "CodexRemote", title: nil, version: "0.1.0"),
            capabilities: nil)
        let result = try await client.send(method: RPCMethod.initialize,
                                           params: try Self.encode(params))
        serverInfo = try Self.decode(InitializeResponse.self, from: result)
        try await client.notify(method: RPCMethod.initialized, params: nil)

        phase = .ready
        reconnectAttempts = 0
        observeDisconnect(client)
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
            try await establish(config)          // 重新 initialize；线程恢复交后续 store
        } catch {
            phase = .reconnecting
            await reconnectWithBackoff(config)
        }
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
