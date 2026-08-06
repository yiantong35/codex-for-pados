import Foundation
import Crypto
import RelayProtocol

/// relay 房间 + 模式判定：已持久化 stableSessionId → 受信任复连（房间用 stableSessionId）；
/// 否则首配（房间用配对载荷 sessionId）。撮合标签决定 relay 房间号，与握手模式一体。
func relayRoomDecision(store: StableSessionStoring, machineKey: String, payloadSessionId: String)
    -> (room: String, isTrustedReconnect: Bool) {
    if let stable = store.stableSessionId(machineKey: machineKey) { return (stable, true) }
    return (payloadSessionId, false)
}

@MainActor
private func localizedTransportMessage(_ key: String, _ value: String? = nil) -> String {
    let format = L10n.string(key, locale: LocaleManager.currentLocale)
    return value.map { String(format: format, $0) } ?? format
}

/// relay transport 工厂：收已构造配对载荷 → 构造真 ws（URLSessionRelayWSChannel）+ 注入 E2E 密钥/TOFU 的 RelayTransport。
/// `tofuMachineKey` 为该机器的稳定 TOFU 键（MachineConfig id）。
/// 真握手（4 消息）由 RelayTransport 在 doEstablish 的 `awaitHandshake()` 内驱动。
@MainActor
func makeRelayTransport(payload: PairingPayload, tofuMachineKey: String,
                        consumePairingCode: @escaping @Sendable () async -> Void = {}) async throws -> MessageTransport {
    guard let base = URL(string: payload.relayURL) else {
        throw TransportError.proxyFailed(localizedTransportMessage("transport.invalidRelayURL", payload.relayURL))
    }
    // 生产强制 wss：明文 ws（非 loopback）拒绝并明确提示需 wss（D6，fail-closed）。
    do {
        try RelaySchemeValidator.validate(url: base)
    } catch {
        throw TransportError.proxyFailed(localizedTransportMessage("transport.insecureRelayURL", payload.relayURL))
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
    let identity = try e2e.identityKey()   // 持久身份，跨重连复用；落盘失败则配对以明确失败告终
    let tofu = KeychainTOFUStore()
    return RelayTransport(
        channelFactory: channelFactory, pairing: payload,
        ipadIdentity: identity,
        ephemeralProvider: { Curve25519.KeyAgreement.PrivateKey() },   // 每次握手新 ephemeral（前向保密）
        tofu: tofu, tofuMachineKey: tofuMachineKey,
        isTrustedReconnect: decision.isTrustedReconnect, stableSessionStore: stableStore,
        consumePairingCode: consumePairingCode)
}

/// 生产工厂闭包（注入 ConnectionStore.transportFactory）：relay-only → RelayTransport。
/// fail-closed：缺 relay 配置（relayURL 为 nil）即配置错误，结构性 throw，绝不回退 SSH/明文。
@MainActor
func liveTransportFactory(_ config: ConnectionConfig) async throws -> MessageTransport {
    guard let relayURL = config.relayURL else {
        // fail-closed：仅支持 relay，缺 relay 配置即配置错误，绝不回退 SSH/明文。
        throw TransportError.proxyFailed(localizedTransportMessage("transport.missingRelayConfig"))
    }
    let machineId = config.relayTOFUKey.flatMap { UUID(uuidString: $0) }
    // 建连前 peek（不删）：失败可用同一 pc 直接重试不重扫（D3）。受信任复连无 pc → nil → 空 proof。
    let pc = machineId.flatMap { PendingPairingStore.shared.peek(for: $0) } ?? ""
    let payload = PairingPayload(relayURL: relayURL, sessionId: config.relaySessionId,
                                 devIdentityPubB64: config.relayDevIdentityPubB64,
                                 pairingCode: pc, expiresAt: 0)
    // 握手成功（收 SecureReady）后由 RelayTransport 回调消费（跳 MainActor 调 take；对已删键幂等返回 nil）。
    let consume: @Sendable () async -> Void = {
        guard let id = machineId else { return }
        await MainActor.run { _ = PendingPairingStore.shared.take(for: id) }
    }
    // 不变量：正常路径 relayTOFUKey 恒非空（MachineConfig 构造置 id.uuidString）；?? relayURL 仅为
    // 类型收尾兜底，正常路径不可达。assert 固化契约、防未来回归误走兜底（release 下空操作，不改行为）。
    assert(config.relayTOFUKey != nil, "relayTOFUKey 恒应非空；走 ?? relayURL 兜底说明上游契约被破坏")
    return try await makeRelayTransport(payload: payload,
                                        tofuMachineKey: config.relayTOFUKey ?? relayURL,
                                        consumePairingCode: consume)
}
