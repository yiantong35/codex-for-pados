import Foundation
import Crypto
import RelayProtocol

/// 生产 transport 工厂：经 SSH(ed25519) withExec `codex app-server proxy --sock`
/// 接入共享 daemon control socket，通道内做 ws 握手 + 帧编解码（ProxyChannel）。
/// 密钥不进 `ConnectionConfig`，由调用方（CodexRemoteApp 的 transportFactory 闭包）捕获 KeyManager 传入。
@MainActor
func makeSharedDaemonTransport(_ config: ConnectionConfig,
                              key: Curve25519.Signing.PrivateKey) async throws -> MessageTransport {
    let channel = try await SSHClientWrapper.connect(
        host: config.host, sshPort: config.sshPort,
        auth: .ed25519Key(user: config.user, key: key),
        controlSockPath: config.controlSockPath)
    return channel   // ProxyChannel 已在 connect() 内 start()
}

/// relay transport 工厂：解析 `codexrelay://pair?…` 配对载荷 → 构造 RelayTransport。
/// 本 task 只需构造出实例（真 ws 握手 `RelayTransport.connect` 是 Task 10 桩，真连接留 Task 13/真机）；
/// 故此处用一个「尚未连线」的占位 ws 通道建出 `RelayTransport(ws:)`，不驱动 connect、不改 RelayTransport 桩。
/// Task 13 把占位通道替换为真 `URLSessionWebSocketTask` 包装 + 编排 4 消息握手。
@MainActor
func makeRelayTransport(pairing: String) async throws -> MessageTransport {
    _ = try PairingPayload(parsing: pairing)   // 校验载荷格式；relayURL 等留 Task 13 连真 ws
    return RelayTransport(ws: PendingRelayWSChannel())
}

/// 占位 ws 通道：真 ws 网络连接（用 pairing.relayURL）与 4 消息握手编排留 Task 13。
/// 在此之前收发即抛「未连接」，与 `RelayTransport.connect` 桩一致——保证 relay 分支能构造实例、
/// 不误报已连通。
private struct PendingRelayWSChannel: RelayWSChannel {
    func sendText(_ text: String) async throws { throw TransportError.notConnected }
    func receiveText() async throws -> String? { throw TransportError.notConnected }
    func close() async {}
}

/// 生产工厂闭包（注入 ConnectionStore.transportFactory）：按连接类型分派——
/// `.relay`（config.isRelay）→ RelayTransport；否则 → 从 KeyManager 取私钥建 SSH+proxy transport。
/// 密钥取法以 KeyManager 实际 API 为准（`privateKey()`）；缺密钥抛 `sshAuthFailed`。
@MainActor
func liveTransportFactory(_ config: ConnectionConfig) async throws -> MessageTransport {
    if let pairing = config.relayPairing {
        return try await makeRelayTransport(pairing: pairing)
    }
    guard let key = KeyManager().privateKey() else {
        throw TransportError.sshAuthFailed("缺少本机密钥")
    }
    return try await makeSharedDaemonTransport(config, key: key)
}
