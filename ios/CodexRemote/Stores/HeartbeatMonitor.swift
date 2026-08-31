import Foundation

/// app 级端到端心跳调度器（design D1/D5）。
/// 纯调度 + 连续错过计数 + 前后台门控；探针本体（getAuthStatus 往返 + 单次超时）由外部注入。
/// 判活只看「有无回响」，天然跨登录方式；入站已验流量亦计为存活证据（noteInboundActivity）。
@MainActor
final class HeartbeatMonitor {
    struct Config: Sendable {
        var interval: Duration = .seconds(10)
        var missThreshold: Int = 2
        var minimumAcceleratedProbeInterval: Duration = .seconds(10)

        init(interval: Duration = .seconds(10),
             missThreshold: Int = 2,
             minimumAcceleratedProbeInterval: Duration = .seconds(10)) {
            self.interval = interval
            self.missThreshold = missThreshold
            self.minimumAcceleratedProbeInterval = minimumAcceleratedProbeInterval
        }
    }

    private let config: Config
    private let probe: @Sendable () async -> Bool
    private let onUnhealthy: @Sendable () async -> Void
    private let sleep: @Sendable (Duration) async -> Void
    private let now: @Sendable () -> ContinuousClock.Instant

    private var loopTask: Task<Void, Never>?
    private var waitTask: Task<Void, Never>?
    private var consecutiveMisses = 0
    private var foreground = true
    private(set) var tabActive = true
    private var started = false
    private var acceleratedProbePending = false
    private var scheduleChanged = false
    private var lastProbeStartedAt: ContinuousClock.Instant?

    init(config: Config = .init(),
         probe: @escaping @Sendable () async -> Bool,
         onUnhealthy: @escaping @Sendable () async -> Void,
         sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
         now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.config = config
        self.probe = probe
        self.onUnhealthy = onUnhealthy
        self.sleep = sleep
        self.now = now
    }

    func start() {
        started = true
        consecutiveMisses = 0
        acceleratedProbePending = tabActive
        restartLoopIfNeeded()
    }

    func stop() {
        started = false
        loopTask?.cancel()
        loopTask = nil
        waitTask?.cancel()
        waitTask = nil
        consecutiveMisses = 0
        acceleratedProbePending = false
        scheduleChanged = false
    }

    func setForeground(_ active: Bool) {
        foreground = active
        if active {
            acceleratedProbePending = tabActive
            restartLoopIfNeeded()
        } else {
            loopTask?.cancel()
            loopTask = nil
            waitTask?.cancel()
            waitTask = nil
            acceleratedProbePending = false
        }
    }

    /// Tab 活跃态与 app 前后台正交：隐藏 tab 停止应用层心跳，切回时立即补探一次。
    func setTabActive(_ active: Bool) {
        guard tabActive != active else { return }
        tabActive = active
        scheduleChanged = true
        waitTask?.cancel()
        if active {
            requestAcceleratedProbe()
        } else {
            // Hidden sessions remain connected for status badges, but must not wake the
            // radio or execute application-level RPC probes.
            acceleratedProbePending = false
            loopTask?.cancel()
            loopTask = nil
        }
    }

    /// peer-left 等提示只请求一次加速探测。突发提示和探测在途提示均合并到一个 pending 位，
    /// 结果仍进入连续 miss reducer，不具备单次判死权。
    func requestAcceleratedProbe() {
        guard started, foreground, tabActive else { return }
        guard !acceleratedProbePending else { return }
        if let lastProbeStartedAt,
           lastProbeStartedAt.duration(to: now()) < config.minimumAcceleratedProbeInterval {
            return
        }
        acceleratedProbePending = true
        waitTask?.cancel()
        restartLoopIfNeeded()
    }

    /// 流量即活（heartbeat-liveness）：经 E2E 验证的入站流量视同一次存活证据，**仅重置**
    /// 连续 miss 计数——不发探针、不改前后台/tab 门控、不重启循环（回调式，零新增轮询/定时器）。
    /// 远端忙于大响应传输、探针排队超时时，持续到达的已验流量使计数不断归零，不误判死。
    /// 判死权不变：流量停了之后仍需连续 missThreshold 次探针 miss 才判死。
    func noteInboundActivity() {
        consecutiveMisses = 0
    }

    private func restartLoopIfNeeded() {
        guard started, foreground, tabActive, loopTask == nil else { return }
        loopTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if !self.acceleratedProbePending {
                    let waiter = Task { await self.sleep(self.config.interval) }
                    self.waitTask = waiter
                    await waiter.value
                    self.waitTask = nil
                    if Task.isCancelled || !self.started || !self.foreground { return }
                    if self.scheduleChanged {
                        self.scheduleChanged = false
                        continue
                    }
                }
                self.acceleratedProbePending = false
                self.lastProbeStartedAt = self.now()
                let ok = await self.probe()
                if Task.isCancelled || !self.started || !self.foreground { return }
                if ok {
                    self.consecutiveMisses = 0
                } else {
                    self.consecutiveMisses += 1
                    if self.consecutiveMisses >= self.config.missThreshold {
                        self.consecutiveMisses = 0
                        self.loopTask = nil   // 释放句柄，使 start()/回前台可经 restartLoopIfNeeded 重启
                        await self.onUnhealthy()
                        return
                    }
                }
            }
        }
    }
}
