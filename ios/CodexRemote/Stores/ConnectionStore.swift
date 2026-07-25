import Foundation
import Observation
import os

private let connLog = Logger(subsystem: "com.tangyujie.codexremote", category: "connection")

/// 连接超时错误（建连/握手在限定时间内未完成）。
struct ConnectionTimeoutError: LocalizedError {
    var errorDescription: String? { "连接超时（连接或握手在 20 秒内未完成）" }
}

/// 连接配置（共享 daemon：SSH host/user + 远端 control socket 路径）。`.stub` 供测试使用。
/// 鉴权由 SSH（ed25519，密钥在 Keychain，由 KeyManager 管）承担，配置本身不含敏感字段。
struct ConnectionConfig: Sendable {
    var host: String              // macmini SSH host
    var user: String              // SSH 用户名
    var sshPort: Int = 22
    var controlSockPath: String   // 远端 ~/.codex/app-server-control/app-server-control.sock
    /// relay 连接载荷（`codexrelay://pair?…`）。非 nil 表示走 RelayTransport 而非 SSH+proxy；
    /// 此时 host/user/controlSockPath 不适用（transportFactory 按此分派）。
    var relayPairing: String? = nil
    /// relay 连接的 TOFU 稳定键（= MachineConfig id 字符串）。SSH 连接为 nil。
    var relayTOFUKey: String? = nil

    /// relay 连接构造：带配对载荷 + TOFU 稳定键，SSH 字段留空。
    init(relayPairing: String, relayTOFUKey: String? = nil) {
        self.host = ""; self.user = ""; self.sshPort = 0; self.controlSockPath = ""
        self.relayPairing = relayPairing
        self.relayTOFUKey = relayTOFUKey
    }

    /// SSH 连接构造（保持既有调用点签名不变）。
    init(host: String, user: String, sshPort: Int = 22, controlSockPath: String) {
        self.host = host; self.user = user; self.sshPort = sshPort
        self.controlSockPath = controlSockPath
        self.relayPairing = nil
    }

    /// 是否 relay 连接。
    var isRelay: Bool { relayPairing != nil }

    static var stub: ConnectionConfig {
        .init(host: "x", user: "u", sshPort: 22, controlSockPath: "/tmp/s.sock")
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
/// 订阅 transport 控制信号驱动 UI 重连指示与会话 resume。
/// 注：当前共享 daemon 走 SSH+proxy（ProxyChannel），其 control() 为协议默认空流——
/// SSH 通道断线重连属本 change 范围外（Phase 5），故 observeControl 暂收不到 .reconnecting/.ready。
///
/// initialize 语义（spike 2026-06-24 实测坐实）：官方 ws app-server 的 initialize 是**连接级**
/// （per-connection）——每个 ws 连接各自发 initialize 并各自成功返回 InitializeResponse，互不影响，
/// 不存在「进程级单次」语义，自己的连接绝不会拿 -32600 Already initialized。故无「Already initialized
/// 容忍」逻辑：initialize 失败即握手失败，正常落 .failed。
///
/// `transportFactory` 注入便于测试 mock：生产环境传捕获 KeyManager 的闭包
/// （经 SSH+proxy 接共享 daemon 的 ProxyChannel），测试传返回 MockTransport 的闭包。
@Observable
@MainActor
final class ConnectionStore {
    private(set) var phase: ConnectionPhase = .disconnected
    private(set) var serverInfo: InitializeResponse?
    /// 信任被开发机撤销（收到 RejectHello 终态）：UI 据此引导用户回配对入口（RelayPairingImportView）。
    /// 每次新 connect()/disconnect() 重置。仅 .trustRevoked 置位，普通连接失败不置位。
    private(set) var needsRePairing = false
    var rpc: JSONRPCClient?

    private let transportFactory: @Sendable (ConnectionConfig) async throws -> MessageTransport
    /// 建连/握手硬超时（纳秒）。默认 20s；测试可注入更短值以快速复现超时失效路径。
    private let connectTimeoutNanos: UInt64
    private var config: ConnectionConfig?
    private var transport: MessageTransport?
    /// 当前 attempt 正在构建、尚未落地的 transport。超时/被新连接或 disconnect 作废时须关闭它，
    /// 触发其 close() → ProxyChannel 标记握手失败 → awaitHandshake 抛出 → doEstablish 解挂（#1 防泄漏）。
    private var inFlightTransport: MessageTransport?
    private var resumeHandler: (@Sendable () async -> Void)?
    private var controlObserver: Task<Void, Never>?
    /// 本次连接是否已触发过「首连恢复」（rejoinRunningThreads），保证恰好一次。
    /// 每次新 connect()/disconnect() 重置。物理重连走 observeControl 的 .ready，与此独立。
    private var didInitialRejoin = false
    /// 当前连接是否已就绪（phase=.ready），用于在 handler 晚于 .ready 注册时补触发首连恢复。
    private var isReady = false
    /// 当前连接尝试序号：每次新连接 +1；超时也 +1 以作废仍在后台跑的旧 establish。
    private var activeAttempt = 0
    /// app 前台/后台状态（能耗）：转发给底层 transport 以在后台暂停重连。默认前台。
    private var foregroundActive = true

    init(transportFactory: @escaping @Sendable (ConnectionConfig) async throws -> MessageTransport,
         connectTimeoutNanos: UInt64 = 20_000_000_000) {
        self.transportFactory = transportFactory
        self.connectTimeoutNanos = connectTimeoutNanos
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
        if config.isRelay {
            // relay：只需配对载荷非空；SSH host/user/sock 与本机 SSH 密钥前置不适用。
            // 真握手由 RelayTransport 在 doEstablish 的 awaitHandshake() 内驱动（先握手后收loop）。
            guard !(config.relayPairing ?? "").isEmpty else {
                connLog.error("connect 拒绝：relay 配对载荷为空")
                phase = .failed("relay 配对信息缺失")
                return
            }
        } else {
            guard !config.host.isEmpty, !config.user.isEmpty, !config.controlSockPath.isEmpty else {
                connLog.error("connect 拒绝：host/user/sock 路径不完整")
                phase = .failed("请先填写主机、用户名与 control socket 路径")
                return
            }
            guard KeyManager().hasKey else {
                connLog.error("connect 拒绝：本机密钥缺失")
                phase = .failed("缺少本机密钥，请在设置中生成并把公钥加入 authorized_keys")
                return
            }
        }
        self.config = config
        // 新连接作废上一次仍在途的 transport（若上次卡在握手未落地也未超时）：关闭之避免泄漏（#1）。
        if let stale = inFlightTransport {
            inFlightTransport = nil
            Task { await stale.close() }
        }
        activeAttempt += 1
        let attempt = activeAttempt
        phase = .connecting
        // 新连接：重置首连恢复状态（上一次连接的 rejoin 不应抑制本次）。
        didInitialRejoin = false
        isReady = false
        needsRePairing = false   // 新连接清除上一次的信任撤销引导标记
        connLog.info("connect 开始 host=\(config.host, privacy: .public):\(config.sshPort) attempt=\(attempt)")

        // 建连 + 握手任务。仅当仍是当前 attempt 时才落地 phase。
        Task { [weak self] in
            guard let self else { return }
            do {
                let (client, newTransport) = try await self.doEstablish(config)
                guard attempt == self.activeAttempt else {
                    // 本 attempt 已被超时/新连接作废：关掉自己建的 client + transport，
                    // 否则其底层 transport 资源泄漏（旧 WSTransport 会继续自动重连一个已丢弃的连接，H2）。
                    await client.stop()
                    await newTransport.close()
                    return
                }
                self.rpc = client
                self.transport = newTransport
                self.inFlightTransport = nil    // 已落地为 self.transport，不再算「在途」
                self.phase = .ready
                self.isReady = true
                self.observeControl(newTransport)
                // 把当前前台/后台状态同步给新 transport（能耗：后台连接不应持续重连）。
                await newTransport.setForeground(self.foregroundActive)
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
        let timeoutNanos = connectTimeoutNanos
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: timeoutNanos)
            guard let self, attempt == self.activeAttempt, !self.phase.isSettled else { return }
            connLog.error("connect 超时 attempt=\(attempt)")
            self.phase = .failed(ConnectionTimeoutError().errorDescription ?? "连接超时")
            self.activeAttempt += 1   // 作废仍在后台跑的 establish（其完成时 token 不匹配 → 忽略）
            // #1：关闭本 attempt 仍在构建的在途 transport，令其 close() 运行（ProxyChannel 标记
            // 握手失败 → awaitHandshake 抛出 → doEstablish 解挂），避免 SSH 连接 + 挂起任务泄漏。
            let inflight = self.inFlightTransport
            self.inFlightTransport = nil
            await inflight?.close()
        }
    }

    /// 主动断开（停止控制信号观察 + 关闭 RPC + 关闭底层 transport）。
    func disconnect() async {
        activeAttempt += 1                // 作废任何在途连接
        controlObserver?.cancel()
        controlObserver = nil
        if let rpc { await rpc.stop() }
        rpc = nil
        // 关闭底层 transport：须在置 nil 前 close，释放通道资源
        // （旧 WSTransport 不 close 会自动重连一个 UI 已丢弃的连接并继续 yield，H2）。
        if let transport { await transport.close() }
        transport = nil
        // 作废任何仍在握手途中、尚未落地的 transport，避免其 SSH 连接 + 挂起任务泄漏（#1）。
        if let inflight = inFlightTransport { await inflight.close() }
        inFlightTransport = nil
        isReady = false
        didInitialRejoin = false
        phase = .disconnected
    }

    /// app 生命周期 → 传输层能耗钩子（4.5）：转发前台/后台状态给当前活跃 transport。
    /// 后台时 RelayTransport 挂起重连循环不烧电；回前台恢复。记录状态以便新建 transport 时同步。
    /// 非 relay transport 走默认空实现，无副作用。
    func setForeground(_ active: Bool) {
        foregroundActive = active
        guard let transport else { return }
        Task { await transport.setForeground(active) }
    }

    // MARK: - 握手

    /// 建底层 transport + initialize 握手，返回就绪的 JSON-RPC client 及其 transport。
    /// initialize 是连接级（spike 实测）：本连接发 initialize 期待自己的 InitializeResponse，
    /// 失败即握手失败（向上抛出，由 connect 落 .failed），不做任何 -32600 特殊容忍。
    /// 不直接落 phase=.ready，也不写 self.transport（由调用方按 attempt token 判定后落地，
    /// 避免被作废的 attempt 污染 self.transport / 泄漏 transport，H2）。
    private func doEstablish(_ config: ConnectionConfig) async throws -> (JSONRPCClient, MessageTransport) {
        phase = .connecting
        connLog.notice("doEstablish: 开始建 transport…")
        let transport = try await transportFactory(config)
        // 记录在途 transport：超时/被作废时由调用方关闭它以解挂 awaitHandshake（#1 防泄漏）。
        inFlightTransport = transport
        connLog.notice("doEstablish: transport 就绪, 启动 JSONRPCClient")
        let client = JSONRPCClient(transport: transport)
        await client.start()

        connLog.notice("doEstablish: 等待 ws 握手完成…")
        try await transport.awaitHandshake()

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
    /// 重连成功（.ready）后经 resumeHandler 触发会话恢复（§5：thread/loaded/list + thread/resume rejoin）。
    /// 注意：首连成功走 connect 里直接落 .ready（不经此处），其首连恢复由 connect 落 .ready /
    /// setResumeHandler 经 triggerInitialRejoinIfReady 触发（恰好一次）。
    /// 当前 ProxyChannel(SSH+proxy) 的 control() 是协议默认空流——SSH 通道断线重连属本 change
    /// 范围外（Phase 5），故此处暂收不到事件；待 Phase 5 实现 SSH 重连后再经此分支触发物理重连恢复。
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
                case .connectionFailed:
                    // 重连退避耗尽（终态，4.3）：落 .failed 提示可手动重连。
                    // **保留机器配置**（不清 config、不 disconnect）——用户可再次 connect() 手动重连。
                    self.phase = .failed("连接失败，请稍后重试")
                case .trustRevoked:
                    // 收到 RejectHello = 开发机移除信任（终态，4.4）：落 .failed 并置位 needsRePairing，
                    // 由 UI 据此导航回配对入口（RelayPairingImportView）。仅此路径要求重新配对，
                    // 其它连接问题（含开发机未开）走 .connectionFailed，不误报信任撤销。
                    self.phase = .failed("已被开发机移除信任，请重新配对")
                    self.needsRePairing = true
                }
            }
        }
    }

    /// 把底层错误转为面向用户的可读文案。
    static func friendlyMessage(_ error: Error) -> String {
        if let t = error as? TransportError {
            switch t {
            case .proxyFailed(let m):    return "通道建立失败：\(m)"
            case .channelClosed(let r):  return "连接通道关闭：\(r ?? "未知原因")"
            case .notConnected:          return "未连接"
            case .sshAuthFailed(let m):  return "SSH 鉴权失败：\(m)"
            case .handshakeFailed(let m): return "WebSocket 握手失败：\(m)"
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
