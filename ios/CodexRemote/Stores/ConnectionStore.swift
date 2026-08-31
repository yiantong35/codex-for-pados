import Foundation
import Observation
import os
import RelayProtocol

private let connLog = Logger(subsystem: "com.tangyujie.codexremote", category: "connection")

/// 连接超时错误（建连/握手在限定时间内未完成）。
struct ConnectionTimeoutError: LocalizedError {
    var errorDescription: String? { L10n.string("conn.error.timeoutDetail", locale: LocaleManager.currentLocale) }
}

/// 连接配置（relay-only：非密的 relay 配对载荷 + TOFU 稳定键）。`.stub` 供测试使用。
/// 鉴权由 relay 的 E2E（Ed25519 身份 + X25519 前向保密 + TOFU）承担，配置本身不含敏感字段。
/// 配对码（pc）绝不进这里，只驻内存 PendingPairingStore，由 liveTransportFactory 现取现用。
struct ConnectionConfig: Sendable {
    /// relay 服务地址。为 nil 视为配置缺失，transportFactory fail-closed throw（绝不回退明文）。
    var relayURL: String? = nil
    var relaySessionId: String = ""
    var relayDevIdentityPubB64: String = ""
    /// relay 连接的 TOFU 稳定键（= MachineConfig id 字符串）。
    var relayTOFUKey: String? = nil

    /// relay 连接构造：带结构化非密字段 + TOFU 稳定键。
    init(relayURL: String, relaySessionId: String, relayDevIdentityPubB64: String, relayTOFUKey: String? = nil) {
        self.relayURL = relayURL; self.relaySessionId = relaySessionId
        self.relayDevIdentityPubB64 = relayDevIdentityPubB64; self.relayTOFUKey = relayTOFUKey
    }

    static var stub: ConnectionConfig {
        .init(relayURL: "wss://stub.invalid", relaySessionId: "stub", relayDevIdentityPubB64: "")
    }
}

/// 心跳判死回调的逃逸包装（Sendable）：封装 `onUnhealthy`，供注入的 heartbeatFactory 构造
/// 脚本化 HeartbeatMonitor 时复用同一份「判死 → 有界重连」副作用。
struct HeartbeatUnhealthy: Sendable {
    let run: @Sendable () async -> Void
}

/// D2：resume 订阅者的轻量唯一标识。
struct ResumeToken: Hashable, Sendable { let raw: UInt64 }

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
/// relay-only：底层 transport 为 RelayTransport，其 control() 会发 .reconnecting/.ready/
/// .connectionFailed/.trustRevoked，由 observeControl 消费驱动 UI 与会话恢复。
///
/// initialize 语义（spike 2026-06-24 实测坐实）：官方 ws app-server 的 initialize 是**连接级**
/// （per-connection）——每个 ws 连接各自发 initialize 并各自成功返回 InitializeResponse，互不影响，
/// 不存在「进程级单次」语义，自己的连接绝不会拿 -32600 Already initialized。故无「Already initialized
/// 容忍」逻辑：initialize 失败即握手失败，正常落 .failed。
///
/// `transportFactory` 注入便于测试 mock：生产环境传 liveTransportFactory（relay-only，
/// 构造 RelayTransport），测试传返回 MockTransport 的闭包。
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
    /// 心跳探针单次超时（纳秒）。默认 10s；测试可注入更短值以复现超时 miss 路径。
    private let heartbeatProbeTimeoutNanos: UInt64
    private var config: ConnectionConfig?
    /// 最近一次 connect 的配置：心跳判死后经 reconnect() 复用它重连（保留机器配置）。
    private var lastConfig: ConnectionConfig?
    /// 端到端心跳调度器（探穿段 B）。仅在 .ready 期间存活；离开 .ready / 断开 / 退后台停止。
    private var heartbeat: HeartbeatMonitor?
    /// 注入的心跳工厂（测试脚本化 probe/onUnhealthy）；生产为 nil，走 makeRealHeartbeat。
    private let injectedHeartbeatFactory: (@MainActor (HeartbeatUnhealthy) -> HeartbeatMonitor)?
    private var transport: MessageTransport?
    /// 当前 attempt 正在构建、尚未落地的 transport。超时/被新连接或 disconnect 作废时须关闭它，
    /// 触发其 close() → transport 标记握手失败 → awaitHandshake 抛出 → doEstablish 解挂（#1 防泄漏）。
    private var inFlightTransport: MessageTransport?
    private struct ResumeRegistration {
        let threadId: String?
        let handler: @Sendable () async -> Void
    }

    /// 可见会话只负责恢复自己的 thread；全量 running-thread rejoin 由连接级恢复任务统一执行。
    private var resumeHandlers: [ResumeToken: ResumeRegistration] = [:]
    /// 已首连补触发过的订阅者集合（订阅者维度化的 didInitialRejoin）：新订阅者不漏、老订阅者不重。
    /// 每次新 connect()/disconnect() 清空。物理重连走 observeControl 的 .ready，与此独立。
    private var rejoinedTokens: Set<ResumeToken> = []
    private var nextResumeTokenRaw: UInt64 = 0
    private var recoveryTask: Task<Void, Never>?
    private var recoveryEpoch: UInt64 = 0
    private var controlObserver: Task<Void, Never>?
    private var connectTimeoutTask: Task<Void, Never>?
    /// 当前连接尝试序号：每次新连接 +1；超时也 +1 以作废仍在后台跑的旧 establish。
    private var activeAttempt = 0
    /// app 前台/后台状态（能耗）：转发给底层 transport 以在后台暂停重连。默认前台。
    /// private(set)：外部（含单测）只读，写入仍仅经 setForeground(_:)。
    private(set) var foregroundActive = true
    /// 当前机器 tab 是否活跃；与 app 前后台正交，用于心跳 10s/60s 分级。
    private(set) var tabActive = false

    #if DEBUG
    /// 测试专用只读访问器：暴露在途 transport 引用以断言 fail-closed 清理（F6）。
    /// `inFlightTransport` 本身对生产代码保持 private；仅测试经 `@testable import` 需要可见性。
    var inFlightTransportForTesting: MessageTransport? { inFlightTransport }
    #endif

    init(transportFactory: @escaping @Sendable (ConnectionConfig) async throws -> MessageTransport,
         connectTimeoutNanos: UInt64 = 20_000_000_000,
         heartbeatProbeTimeoutNanos: UInt64 = 10_000_000_000,
         heartbeatFactory: (@MainActor (HeartbeatUnhealthy) -> HeartbeatMonitor)? = nil) {
        self.transportFactory = transportFactory
        self.connectTimeoutNanos = connectTimeoutNanos
        self.heartbeatProbeTimeoutNanos = heartbeatProbeTimeoutNanos
        self.injectedHeartbeatFactory = heartbeatFactory
    }

    /// D2：登记一个「重连后恢复当前可见会话」回调，返回轻量唯一 token 供精确注销。
    /// 真实接线中 ConversationView 在 rpc 就绪后才注册，可能晚于首连 .ready——
    /// 故注册时若连接已就绪且该 token 尚未首连触发过，立即补触发恰一次
    /// 主对话与每个侧聊各自订阅、互不覆盖；其它运行中 thread 由连接级任务统一恢复。
    @discardableResult
    func addResumeHandler(threadId: String? = nil,
                          _ h: @escaping @Sendable () async -> Void) -> ResumeToken {
        let token = ResumeToken(raw: nextResumeTokenRaw); nextResumeTokenRaw &+= 1
        resumeHandlers[token] = ResumeRegistration(threadId: threadId, handler: h)
        // 已就绪且本 token 尚未首连触发过 → 立即补触发恰一次（对齐既有 setResumeHandler 语义）。
        if phase == .ready, !rejoinedTokens.contains(token) {
            rejoinedTokens.insert(token)
            Task { await h() }
        }
        return token
    }

    /// D2：精确注销单个订阅者，不影响其它订阅者。
    func removeResumeHandler(_ token: ResumeToken) {
        resumeHandlers[token] = nil
        rejoinedTokens.remove(token)
    }

    /// 薄封装：保留旧调用点/旧测试。忽略返回 token（无法精确注销，仅供不需注销的场景）。
    func setResumeHandler(_ h: @escaping @Sendable () async -> Void) {
        _ = addResumeHandler(h)
    }

    /// 首连恢复触发器：为当前 ready epoch 启动一轮连接级恢复。
    /// addResumeHandler 晚于首连 .ready 时，会单独补恢复新出现的可见会话。
    /// 物理重连的恢复由 observeControl 的 .ready 分支独立负责，不经此处。
    private func triggerInitialRejoinIfReady() {
        guard phase == .ready else { return }
        scheduleRecoveryEpoch()
    }

    /// 每个 ready epoch 只创建一个恢复任务。它先让每个可见 store 恢复自己的 thread，再用一次
    /// loaded/list 恢复其余运行中 thread 的订阅副作用；新 epoch 会取消旧任务并用序号阻止迟到结果继续发 RPC。
    private func scheduleRecoveryEpoch() {
        recoveryTask?.cancel()
        recoveryEpoch &+= 1
        let epoch = recoveryEpoch
        let registrations = resumeHandlers
        rejoinedTokens.formUnion(registrations.keys)
        recoveryTask = Task { [weak self] in
            guard let self else { return }
            let visibleThreadIds = Set(registrations.values.compactMap(\.threadId))
            await withTaskGroup(of: Void.self) { group in
                for registration in registrations.values {
                    group.addTask { await registration.handler() }
                }
                group.addTask { [weak self] in
                    await self?.rejoinLoadedThreads(excluding: visibleThreadIds, epoch: epoch)
                }
                await group.waitForAll()
            }
        }
    }

    private func rejoinLoadedThreads(excluding visibleThreadIds: Set<String>, epoch: UInt64) async {
        guard !Task.isCancelled, epoch == recoveryEpoch, let rpc else { return }
        guard let listResult = try? await rpc.send(
            method: RPCMethod.threadLoadedList,
            params: try? Self.encode(EmptyParams())
        ), let list = try? Self.decode(LoadedThreadList.self, from: listResult) else { return }

        for threadId in list.data where !visibleThreadIds.contains(threadId) {
            guard !Task.isCancelled, epoch == recoveryEpoch else { return }
            let params = try? Self.encode(ThreadResumeParams(threadId: threadId, model: nil, cwd: nil))
            _ = try? await rpc.send(method: RPCMethod.threadResume, params: params)
        }
    }

    /// 发起连接（fire-and-forget，结果经 `phase` 反映给 UI）。
    /// 新连接立即把 phase 置为 connecting → 自动清除上一次的 .failed 错误。
    /// 含 20s 硬超时：建连/握手卡住时强制转 .failed 并作废后台残留任务。
    func connect(config: ConnectionConfig) {
        // relay-only：只需配对载荷非空。真握手由 RelayTransport 在 doEstablish 的
        // awaitHandshake() 内驱动（先握手后收loop）。
        guard !(config.relayURL ?? "").isEmpty else {
            connLog.error("connect 拒绝：relay 配对载荷为空")
            phase = .failed(L10n.string("conn.error.pairingMissing", locale: LocaleManager.currentLocale))
            return
        }
        self.config = config
        self.lastConfig = config    // 记录以供心跳判死后 reconnect() 复用（保留机器配置）
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        // 新连接作废上一次仍在途的 transport（若上次卡在握手未落地也未超时）：关闭之避免泄漏（#1）。
        if let stale = inFlightTransport {
            inFlightTransport = nil
            Task { await stale.close() }
        }
        activeAttempt += 1
        let attempt = activeAttempt
        phase = .connecting
        // 新连接：重置首连恢复状态（上一次连接的 rejoin 不应抑制本次）。
        recoveryTask?.cancel()
        recoveryTask = nil
        recoveryEpoch &+= 1
        rejoinedTokens.removeAll()
        needsRePairing = false   // 新连接清除上一次的信任撤销引导标记
        connLog.info("connect 开始 relay session=\(config.relaySessionId, privacy: .public) attempt=\(attempt)")

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
                self.connectTimeoutTask?.cancel()
                self.connectTimeoutTask = nil
                self.startHeartbeat()   // 首连就绪：起端到端心跳探穿段 B
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
                self.connectTimeoutTask?.cancel()
                self.connectTimeoutTask = nil
                connLog.error("connect 失败: \(String(describing: error), privacy: .public)")
                // #2 冷启动首连即遇 trustRevoked：RelayTransport 首连收 RejectHello 以可判别类型
                // .trustRevoked 冒泡（observeControl 尚未订阅，控制事件无人消费）。与 live 重连路径的
                // .trustRevoked 处理一致：置位 needsRePairing + 撤销引导文案，UI 据此导航回配对入口。
                if case TransportError.trustRevoked = error {
                    self.phase = .failed(L10n.string("conn.error.trustRevoked", locale: LocaleManager.currentLocale))
                    self.needsRePairing = true
                } else if case TransportError.handshakeRejected(let reason) = error {
                    self.phase = .failed(Self.rejectionMessage(reason))
                    self.needsRePairing = Self.rejectionNeedsPairing(reason)
                } else {
                    self.phase = .failed(Self.friendlyMessage(error))
                }
            }
        }

        // 硬超时：到点若仍未 settle，强制失败并作废本次 attempt。
        let timeoutNanos = connectTimeoutNanos
        connectTimeoutTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: timeoutNanos) }
            catch { return }
            guard let self, attempt == self.activeAttempt else { return }
            self.connectTimeoutTask = nil
            connLog.error("connect 超时 attempt=\(attempt)")
            self.phase = .failed(ConnectionTimeoutError().errorDescription
                ?? L10n.string("conn.error.timeout", locale: LocaleManager.currentLocale))
            self.activeAttempt += 1   // 作废仍在后台跑的 establish（其完成时 token 不匹配 → 忽略）
            // #1：关闭本 attempt 仍在构建的在途 transport，令其 close() 运行（transport 标记
            // 握手失败 → awaitHandshake 抛出 → doEstablish 解挂），避免传输连接 + 挂起任务泄漏。
            let inflight = self.inFlightTransport
            self.inFlightTransport = nil
            await inflight?.close()
        }
    }

    /// 主动断开（停止控制信号观察 + 关闭 RPC + 关闭底层 transport）。
    func disconnect() async {
        activeAttempt += 1                // 作废任何在途连接
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        stopHeartbeat()                   // 主动断开：停心跳（终态不重连）
        controlObserver?.cancel()
        controlObserver = nil
        if let rpc { await rpc.stop() }
        rpc = nil
        // 关闭底层 transport：须在置 nil 前 close，释放通道资源
        // （旧 WSTransport 不 close 会自动重连一个 UI 已丢弃的连接并继续 yield，H2）。
        if let transport { await transport.close() }
        transport = nil
        // 作废任何仍在握手途中、尚未落地的 transport，避免其传输连接 + 挂起任务泄漏（#1）。
        // take-and-nil：先原子取所有权再 close，避免与在途 establish 的失败清理路径双关同一 transport。
        if let inflight = inFlightTransport { inFlightTransport = nil; await inflight.close() }
        recoveryTask?.cancel()
        recoveryTask = nil
        recoveryEpoch &+= 1
        rejoinedTokens.removeAll()
        phase = .disconnected
    }

    /// app 生命周期 → 传输层能耗钩子（4.5）：转发前台/后台状态给当前活跃 transport。
    /// 后台时 RelayTransport 挂起重连循环不烧电；回前台恢复。记录状态以便新建 transport 时同步。
    func setForeground(_ active: Bool) {
        foregroundActive = active
        // 已落地 transport：转发状态（RelayTransport 后台暂停重连）。
        if let transport { Task { await transport.setForeground(active) } }
        // #7：在途首连（尚未落地的 inFlightTransport）也要覆盖——退后台时取消它，避免最长烧到 20s 超时。
        // 走既有 attempt-token 作废 + take-and-nil 关闭路径（与 disconnect / 超时兜底一致，exactly-once）。
        if !active, let inflight = inFlightTransport {
            inFlightTransport = nil          // take-and-nil：原子取所有权，防与 doEstablish catch 双关
            activeAttempt += 1               // 作废本次 attempt：其 establish 完成时 token 不匹配 → 忽略
            Task { await inflight.close() }  // close() → awaitHandshake 抛出 → doEstablish 解挂并 fail-closed
            // 必须自行落终态：作废 attempt 后，connect 的 establish catch 会因 `attempt != activeAttempt`
            // 提前 return 而不落任何 phase（原本靠 20s 超时兜底落 .failed，此处即时取消已绕过它），
            // phase 会永远卡在 .connecting/.initializing → UI 连接按钮转圈禁用、needsConnect/自动重连门
            // （均要求 .disconnected）失效，回前台无从重试。退后台是**主动暂停**非连接失败，故落
            // .disconnected（与 disconnect() 的终态一致），使回前台 needsConnect==true 可重连。
            stopHeartbeat()   // 退后台取消在途首连并落终态：一并停心跳
            phase = .disconnected
        }
        // 能耗：心跳前后台门控——后台暂停探针循环，回前台恢复并立即补发一次探活。
        heartbeat?.setForeground(active)
    }

    func setTabActive(_ active: Bool) {
        tabActive = active
        heartbeat?.setTabActive(active)
    }

    /// Close a hidden-tab connection only if the tab is still hidden when this
    /// asynchronous operation reaches the actor. This prevents a stale hide task
    /// from closing a newly reconnected active tab.
    func disconnectIfTabInactive() async {
        guard !tabActive else { return }
        await disconnect()
    }

    // MARK: - 握手

    /// 建底层 transport + initialize 握手，返回就绪的 JSON-RPC client 及其 transport。
    /// initialize 是连接级（spike 实测）：本连接发 initialize 期待自己的 InitializeResponse，
    /// 失败即握手失败（向上抛出，由 connect 落 .failed），不做任何 -32600 特殊容忍。
    /// 不直接落 phase=.ready，也不写 self.transport（由调用方按 attempt token 判定后落地，
    /// 避免被作废的 attempt 污染 self.transport / 泄漏 transport，H2）。
    private func doEstablish(_ config: ConnectionConfig) async throws -> (JSONRPCClient, MessageTransport) {
        phase = .connecting
        // #7 纵深防御：后台不发起首连（主取消路径是 setForeground 的 take-and-nil close）。
        guard foregroundActive else { throw TransportError.notConnected }
        connLog.notice("doEstablish: 开始建 transport…")
        let transport = try await transportFactory(config)
        // 记录在途 transport：超时/被作废时由调用方关闭它以解挂 awaitHandshake（#1 防泄漏）。
        inFlightTransport = transport
        connLog.notice("doEstablish: transport 就绪, 启动 JSONRPCClient")
        let client = JSONRPCClient(transport: transport)
        // 流量即活挂钩（heartbeat-liveness）：client 每成功解码一条入站消息（已验明文）
        // 即回调重置心跳连续 miss 计数。挂在 doEstablish = 所有落地连接（首连/手动重连）统一生效。
        await client.setInboundActivityHandler { [weak self] in
            Task { @MainActor in self?.noteInboundActivity() }
        }
        await client.start()

        do {
            connLog.notice("doEstablish: 等待 ws 握手完成…")
            // #7 纵深防御：建 transport 到此的异步窗口内可能已退后台（退后台路径已作废 attempt 并关 transport）。
            guard foregroundActive else { throw TransportError.notConnected }
            try await transport.awaitHandshake()

            phase = .initializing
            connLog.notice("doEstablish: 发送 initialize, 等响应…")
            let params = InitializeParams(
                clientInfo: ClientInfo(name: "CodexRemote", title: nil, version: "0.1.0"),
                capabilities: nil)
            // 连接级 initialize：失败直接抛出（不容忍 -32600），由 catch 做 fail-closed 清理后向上抛。
            let result = try await client.send(method: RPCMethod.initialize,
                                               params: try Self.encode(params))
            serverInfo = try? Self.decode(InitializeResponse.self, from: result)
            try? await client.notify(method: RPCMethod.initialized, params: nil)
            connLog.notice("doEstablish: 握手完成")
            return (client, transport)
        } catch {
            // F6 fail-closed：transport 与接收循环在 initialize 之前已启动、inFlightTransport 已设；
            // 握手/initialize 失败必须显式清理，不能只让调用方落 .failed 而遗留打开的连接与悬挂接收任务
            // ——settled 超时兜底（:217 !phase.isSettled）在 phase 落 .failed 后不会触发，无法兜底。
            // 与「attempt 被后续新连接取代」的清理路径（connect:159-163）一致。
            connLog.error("doEstablish: 握手/initialize 失败，fail-closed 清理: \(String(describing: error), privacy: .public)")
            // client 为本 establish 独占的局部量（未落地 self.rpc），无论谁关 transport 都须 stop
            // 以免接收循环泄漏，故 client.stop() 不入所有权判断、无条件执行。
            await client.stop()
            // take-and-nil 原子取所有权后再 close：仅当仍持有本 transport（inFlightTransport 未被
            // 超时兜底 / 新连接作废 / disconnect 抢先取走）时才关闭它，令同一 transport 恰好 close 一次——
            // 消除与超时兜底路径（connect 内 :229-231）对同一 transport 的双关竞态（双 close → closeCount=2）。
            // 若已被抢走（identity 不匹配或已 nil），对方已负责 close，此处不得重复关闭，否则重复关闭。
            // 恒等判断：`MessageTransport` 协议本身未约束 AnyObject（existential 不能直接 `===`），
            // 但本仓库全部实现均为引用类型（class/actor），经 `as AnyObject` 装箱后按引用比较等价于 `===`。
            if let inflight = inFlightTransport, (inflight as AnyObject) === (transport as AnyObject) {
                inFlightTransport = nil
                await inflight.close()
            }
            throw error
        }
    }

    // MARK: - 端到端心跳（探穿段 B：iPad→relay→Mac subprocess）

    /// 心跳判死 / peer-left 探针 miss 后触发的重连：复用最近一次机器配置重连（保留配置）。
    /// 注意：真实重连由底层 transport 的有界退避承担（onUnhealthy → transport.triggerReconnect）；
    /// 此方法供 UI「手动重连」按钮（Task 9/横幅）显式复连时调用。
    func reconnect() {
        if let c = lastConfig { connect(config: c) }
    }

    /// 心跳探针本体：一次 getAuthStatus 往返 vs 超时竞速。三分判活——只看「有无回响」不看
    /// 内容（天然跨登录方式）：正常应答=活；远端 error 回响（JSONRPCClient 对 .error 抛
    /// TransportError.proxyFailed）=有回响=活；仅超时或传输层失败（channelClosed/取消等）=miss。
    private func sendHeartbeatProbe() async -> Bool {
        guard let rpc else { return false }
        guard let empty = try? JSONDecoder().decode(AnyCodable.self, from: Data("{}".utf8)) else { return false }
        let timeoutNanos = heartbeatProbeTimeoutNanos
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do { _ = try await rpc.send(method: RPCMethod.getAuthStatus, params: empty); return true }
                catch let error as TransportError {
                    if case .proxyFailed = error { return true }   // 远端 error 回响=活
                    return false                                    // 传输层失败=miss
                }
                catch { return false }                              // 取消/其他=miss
            }
            group.addTask { try? await Task.sleep(nanoseconds: timeoutNanos); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    /// 生产心跳：默认 10s 间隔 / 连续错过 2 次判死，探针走 sendHeartbeatProbe。
    private func makeRealHeartbeat(onUnhealthy: @escaping @Sendable () async -> Void) -> HeartbeatMonitor {
        HeartbeatMonitor(probe: { [weak self] in await self?.sendHeartbeatProbe() ?? false },
                         onUnhealthy: onUnhealthy)
    }

    /// 起心跳（进入 .ready 时调用）：判死回调触发底层 transport 有界重连。测试可经 injectedHeartbeatFactory
    /// 注入脚本化 monitor 复用同一 onUnhealthy。前后台状态即时同步（后台不空转）。
    private func startHeartbeat() {
        heartbeat?.stop()
        let onUnhealthy: @Sendable () async -> Void = { [weak self] in
            await self?.transport?.triggerReconnect()
        }
        let m = injectedHeartbeatFactory?(HeartbeatUnhealthy(run: onUnhealthy))
            ?? makeRealHeartbeat(onUnhealthy: onUnhealthy)
        m.setTabActive(tabActive)
        m.setForeground(foregroundActive)
        m.start()
        heartbeat = m
    }

    /// 停心跳（离开 .ready / 断开 / 退后台取消在途首连）。
    private func stopHeartbeat() {
        heartbeat?.stop()
        heartbeat = nil
    }

    /// 流量即活：转发给当前心跳（仅重置连续 miss 计数；无心跳期间为 no-op）。
    func noteInboundActivity() {
        heartbeat?.noteInboundActivity()
    }

    // MARK: - 控制信号观察

    /// 订阅 transport 控制信号：reconnecting/ready 驱动 UI 重连指示。
    /// 重连成功（.ready）后启动单个连接级恢复任务：可见会话各恢复自身，其余 loaded thread 统一 rejoin。
    /// 注意：首连成功走 connect 里直接落 .ready（不经此处），其首连恢复由 connect 落 .ready /
    /// addResumeHandler 经 triggerInitialRejoinIfReady 触发。
    /// relay-only：RelayTransport 的 control() 在物理断线/重连时发事件，经此分支驱动物理重连恢复。
    private func observeControl(_ transport: MessageTransport) {
        controlObserver?.cancel()
        controlObserver = Task { [weak self] in
            for await ev in transport.control() {
                guard let self else { return }
                switch ev {
                case .reconnecting:
                    self.recoveryTask?.cancel()
                    self.recoveryTask = nil
                    self.recoveryEpoch &+= 1
                    self.phase = .reconnecting
                    self.stopHeartbeat()   // 离开 .ready：停心跳，物理重连成功（.ready）后再起
                    // 物理断线：失败断线瞬间已发出、仍等响应的在途请求，避免其永久挂起（H1）。
                    // 响应不会在新通道重放；失败后调用方/UI 可重试。control() 单消费者由本处独占，
                    // 故由 ConnectionStore（同时持 rpc 与控制流）触发，而非让 JSONRPCClient 抢消费控制流。
                    if let rpc = self.rpc {
                        Task { await rpc.failInflight(TransportError.channelClosed(reason: "reconnecting")) }
                    }
                case .ready:
                    self.phase = .ready
                    self.startHeartbeat()   // 物理重连成功：重启端到端心跳
                    self.scheduleRecoveryEpoch()
                case .connectionFailed:
                    // 重连退避耗尽（终态，4.3）：落 .failed 提示可手动重连。
                    // **保留机器配置**（不清 config、不 disconnect）——用户可再次 connect() 手动重连。
                    self.stopHeartbeat()
                    self.recoveryTask?.cancel()
                    self.recoveryTask = nil
                    self.phase = .failed(L10n.string("conn.error.connectionFailed", locale: LocaleManager.currentLocale))
                case .trustRevoked:
                    // 收到 RejectHello = 开发机移除信任（终态，4.4）：落 .failed 并置位 needsRePairing，
                    // 由 UI 据此导航回配对入口（RelayPairingImportView）。仅此路径要求重新配对，
                    // 其它连接问题（含开发机未开）走 .connectionFailed，不误报信任撤销。
                    self.stopHeartbeat()
                    self.recoveryTask?.cancel()
                    self.recoveryTask = nil
                    self.phase = .failed(L10n.string("conn.error.trustRevoked", locale: LocaleManager.currentLocale))
                    self.needsRePairing = true
                case .handshakeRejected(let reason):
                    self.stopHeartbeat()
                    self.recoveryTask?.cancel()
                    self.recoveryTask = nil
                    self.phase = .failed(Self.rejectionMessage(reason))
                    self.needsRePairing = Self.rejectionNeedsPairing(reason)
                case .peerLeft:
                    // 非判决（防降级红线）：relay 连接层「对端已离开」只是**提示**，不是判死依据。
                    // 恶意/误报 relay 不能凭空杀健康连接——不改 phase、不断开、不重连，
                    // 仅活动 tab 带外补发一次心跳探针核实；非活动 tab 继续遵守 60s 下限，避免
                    // 未认证 relay 信号放大后台连接能耗。探针 miss 才由心跳判死，hit 则忽略。
                    self.heartbeat?.requestAcceleratedProbe()
                }
            }
        }
    }

    /// 把底层错误转为面向用户的可读文案。
    static func friendlyMessage(_ error: Error) -> String {
        let loc = LocaleManager.currentLocale
        if let t = error as? TransportError {
            switch t {
            case .proxyFailed(let m):
                return String(format: L10n.string("conn.error.proxyFailed", locale: loc), m)
            case .channelClosed, .protocolViolation, .inboundBufferOverflow:
                // Transport reasons often contain multi-line NSError/URLSession dumps.
                // Keep those in logs; user-facing surfaces need a stable, actionable summary.
                return L10n.string("conn.error.connectionFailed", locale: loc)
            case .notConnected:
                return L10n.string("conn.error.notConnected", locale: loc)
            case .handshakeFailed(let m):
                return String(format: L10n.string("conn.error.handshakeFailed", locale: loc), m)
            case .trustRevoked:
                return L10n.string("conn.error.trustRevoked", locale: loc)
            case .handshakeRejected(let reason):
                return rejectionMessage(reason)
            case .messageTooLarge(let bytes, let limit):
                return String(
                    format: L10n.string("conn.error.messageTooLarge", locale: loc),
                    Int64(bytes), Int64(limit)
                )
            }
        }
        if let to = error as? ConnectionTimeoutError {
            return to.errorDescription ?? L10n.string("conn.error.timeout", locale: loc)
        }
        return error.localizedDescription
    }

    private static func rejectionNeedsPairing(_ reason: RejectReason) -> Bool {
        reason != .versionMismatch
    }

    private static func rejectionMessage(_ reason: RejectReason) -> String {
        let locale = LocaleManager.currentLocale
        switch reason {
        case .trustRevoked: return L10n.string("conn.error.trustRevoked", locale: locale)
        case .untrusted: return L10n.string("conn.error.untrusted", locale: locale)
        case .pairingInvalid: return L10n.string("conn.error.pairingInvalid", locale: locale)
        case .versionMismatch: return L10n.string("conn.error.versionMismatch", locale: locale)
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

/// Connection banner state. Re-pairing keeps the classified failure reason alongside its action.
enum ConnectionBannerState: Equatable {
    case reconnecting
    case failed(String)
    case rePairingRequired(String)
}

extension ConnectionStore {
    var bannerState: ConnectionBannerState? {
        if needsRePairing {
            if case .failed(let reason) = phase { return .rePairingRequired(reason) }
            return .rePairingRequired(
                L10n.string("conn.error.trustRevoked", locale: LocaleManager.currentLocale))
        }
        switch phase {
        case .reconnecting: return .reconnecting
        case .failed(let reason): return .failed(reason)
        default:            return nil
        }
    }
}

#if DEBUG
extension ConnectionStore {
    func _test_setPhase(_ p: ConnectionPhase) { phase = p }
    /// 测试专用：直接驱动一次心跳探针（三分判活行为测试）。
    func sendHeartbeatProbeForTesting() async -> Bool { await sendHeartbeatProbe() }
    func _test_setTrustRevoked() { phase = .failed("trust"); needsRePairing = true }
    func _test_setRePairingRequired(reason: String) {
        phase = .failed(reason)
        needsRePairing = true
    }
}
#endif
