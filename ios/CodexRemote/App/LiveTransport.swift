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
        controlSockPath: config.controlSockPath,
        machineKey: "\(config.user)@\(config.host):\(config.sshPort)")
    return channel   // ProxyChannel 已在 connect() 内 start()
}

/// relay 房间 + 模式判定：已持久化 stableSessionId → 受信任复连（房间用 stableSessionId）；
/// 否则首配（房间用配对载荷 sessionId）。撮合标签决定 relay 房间号，与握手模式一体。
func relayRoomDecision(store: StableSessionStoring, machineKey: String, payloadSessionId: String)
    -> (room: String, isTrustedReconnect: Bool) {
    if let stable = store.stableSessionId(machineKey: machineKey) { return (stable, true) }
    return (payloadSessionId, false)
}

/// relay transport 工厂：收已构造配对载荷 → 构造真 ws（URLSessionRelayWSChannel）+ 注入 E2E 密钥/TOFU 的 RelayTransport。
/// `tofuMachineKey` 为该机器的稳定 TOFU 键（MachineConfig id）。
/// 真握手（4 消息）由 RelayTransport 在 doEstablish 的 `awaitHandshake()` 内驱动，与 SSH 共用握手等待链。
@MainActor
func makeRelayTransport(payload: PairingPayload, tofuMachineKey: String) async throws -> MessageTransport {
    guard let base = URL(string: payload.relayURL) else {
        throw TransportError.proxyFailed("relayURL 非法: \(payload.relayURL)")
    }
    // 生产强制 wss：明文 ws（非 loopback）拒绝并明确提示需 wss（D6，fail-closed）。
    do {
        try RelaySchemeValidator.validate(url: base)
    } catch {
        throw TransportError.proxyFailed("relay 地址为明文 ws，生产环境需使用加密的 wss: \(payload.relayURL)")
    }
    // 房间号 + 握手模式由已持久化的 stableSessionId 决定：复连直连受信任房间免 pairingCode。
    let stableStore = UserDefaultsStableSessionStore()
    let decision = relayRoomDecision(store: stableStore, machineKey: tofuMachineKey,
                                     payloadSessionId: payload.sessionId)
    // 与 dev 拨出对齐：路径 /relay/{room}，header x-role: iPad。
    let wsURL = base.appendingPathComponent("relay").appendingPathComponent(decision.room)
    // channel factory：首连与每次重连各造一条全新 URLSessionRelayWSChannel（旧通道已断，须新 task）。
    let channelFactory: @Sendable () async throws -> RelayWSChannel = {
        var req = URLRequest(url: wsURL)
        req.setValue(RelayPeer.iPad.rawValue, forHTTPHeaderField: "x-role")
        let task = URLSession.shared.webSocketTask(with: req)
        return URLSessionRelayWSChannel(task: task)   // 内部 task.resume()
    }

    let e2e = RelayE2EKeyManager()
    let identity = e2e.identityKey()   // 持久身份，跨重连复用
    let tofu = KeychainTOFUStore()
    return RelayTransport(
        channelFactory: channelFactory, pairing: payload,
        ipadIdentity: identity,
        ephemeralProvider: { Curve25519.KeyAgreement.PrivateKey() },   // 每次握手新 ephemeral（前向保密）
        tofu: tofu, tofuMachineKey: tofuMachineKey,
        isTrustedReconnect: decision.isTrustedReconnect, stableSessionStore: stableStore)
}

/// 生产工厂闭包（注入 ConnectionStore.transportFactory）：按连接类型分派——
/// `.relay`（config.isRelay）→ RelayTransport；否则 → 从 KeyManager 取私钥建 SSH+proxy transport。
/// 密钥取法以 KeyManager 实际 API 为准（`privateKey()`）；缺密钥抛 `sshAuthFailed`。
@MainActor
func liveTransportFactory(_ config: ConnectionConfig) async throws -> MessageTransport {
    if let relayURL = config.relayURL {
        let machineId = config.relayTOFUKey.flatMap { UUID(uuidString: $0) }
        // 一次性取内存 pending pc（首配用；受信任复连为 nil，走空 proof 路径）。
        let pc = machineId.flatMap { PendingPairingStore.shared.take(for: $0) } ?? ""
        let payload = PairingPayload(relayURL: relayURL, sessionId: config.relaySessionId,
                                     devIdentityPubB64: config.relayDevIdentityPubB64,
                                     pairingCode: pc, expiresAt: 0)
        return try await makeRelayTransport(payload: payload,
                                            tofuMachineKey: config.relayTOFUKey ?? relayURL)
    }
    guard let key = KeyManager().privateKey() else {
        throw TransportError.sshAuthFailed("缺少本机密钥")
    }
    return try await makeSharedDaemonTransport(config, key: key)
}
