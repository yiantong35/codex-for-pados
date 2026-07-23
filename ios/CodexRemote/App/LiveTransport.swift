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

/// relay transport 工厂：解析配对载荷 → 构造真 ws（URLSessionRelayWSChannel）+ 注入 E2E 密钥/TOFU 的 RelayTransport。
/// `tofuMachineKey` 为该机器的稳定 TOFU 键（MachineConfig id）。
/// 真握手（4 消息）由 RelayTransport 在 doEstablish 的 `awaitHandshake()` 内驱动，与 SSH 共用握手等待链。
@MainActor
func makeRelayTransport(pairing: String, tofuMachineKey: String) async throws -> MessageTransport {
    let payload = try PairingPayload(parsing: pairing)
    guard let base = URL(string: payload.relayURL) else {
        throw TransportError.proxyFailed("relayURL 非法: \(payload.relayURL)")
    }
    // 与 dev 拨出对齐：路径 /relay/{sessionId}，header x-role: iPad。
    let wsURL = base.appendingPathComponent("relay").appendingPathComponent(payload.sessionId)
    var req = URLRequest(url: wsURL)
    req.setValue(RelayPeer.iPad.rawValue, forHTTPHeaderField: "x-role")
    let task = URLSession.shared.webSocketTask(with: req)
    let channel = URLSessionRelayWSChannel(task: task)   // 内部 task.resume()

    let e2e = RelayE2EKeyManager()
    let tofu = KeychainTOFUStore()
    return RelayTransport(
        ws: channel, pairing: payload,
        ipadIdentity: e2e.identityKey(), ipadEphemeral: e2e.newEphemeralKey(),
        tofu: tofu, tofuMachineKey: tofuMachineKey)
}

/// 生产工厂闭包（注入 ConnectionStore.transportFactory）：按连接类型分派——
/// `.relay`（config.isRelay）→ RelayTransport；否则 → 从 KeyManager 取私钥建 SSH+proxy transport。
/// 密钥取法以 KeyManager 实际 API 为准（`privateKey()`）；缺密钥抛 `sshAuthFailed`。
@MainActor
func liveTransportFactory(_ config: ConnectionConfig) async throws -> MessageTransport {
    if let pairing = config.relayPairing {
        return try await makeRelayTransport(pairing: pairing,
                                            tofuMachineKey: config.relayTOFUKey ?? pairing)
    }
    guard let key = KeyManager().privateKey() else {
        throw TransportError.sshAuthFailed("缺少本机密钥")
    }
    return try await makeSharedDaemonTransport(config, key: key)
}
