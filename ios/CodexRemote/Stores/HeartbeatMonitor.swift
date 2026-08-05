import Foundation

/// app 级端到端心跳调度器（design D1/D5）。
/// 纯调度 + 连续错过计数 + 前后台门控；探针本体（getAuthStatus 往返 + 单次超时）由外部注入。
/// 判活只看「有无回响」，天然跨登录方式。
@MainActor
final class HeartbeatMonitor {
    struct Config: Sendable {
        var interval: Duration = .seconds(10)
        var missThreshold: Int = 2
    }

    private let config: Config
    private let probe: @Sendable () async -> Bool
    private let onUnhealthy: @Sendable () async -> Void
    private let sleep: @Sendable (Duration) async -> Void

    private var loopTask: Task<Void, Never>?
    private var consecutiveMisses = 0
    private var foreground = true
    private var started = false

    init(config: Config = .init(),
         probe: @escaping @Sendable () async -> Bool,
         onUnhealthy: @escaping @Sendable () async -> Void,
         sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.config = config
        self.probe = probe
        self.onUnhealthy = onUnhealthy
        self.sleep = sleep
    }

    func start() {
        started = true
        consecutiveMisses = 0
        restartLoopIfNeeded()
    }

    func stop() {
        started = false
        loopTask?.cancel()
        loopTask = nil
        consecutiveMisses = 0
    }

    func setForeground(_ active: Bool) {
        foreground = active
        if active {
            // 回前台：仅重启可取消 loop。loop 首轮不 sleep、立即探一次（见 restartLoopIfNeeded），
            // 故「回前台立即补探」已并入 loop，无需再起游离 Task{probeOnce}——后者会造成双探针，
            // 且 probeOnce 单次 miss 即判死、绕过 missThreshold（#11）。
            restartLoopIfNeeded()
        } else {
            loopTask?.cancel()           // 后台暂停：不维持前台级唤醒
            loopTask = nil
        }
    }

    /// 带外单次探活（peer-left 核实）：未回响即判死，有回响忽略。
    func probeOnce() async {
        let ok = await probe()
        if !ok { await onUnhealthy() }
    }

    private func restartLoopIfNeeded() {
        guard started, foreground, loopTask == nil else { return }
        loopTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let ok = await self.probe()
                if Task.isCancelled { return }
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
                await self.sleep(self.config.interval)
            }
        }
    }
}
