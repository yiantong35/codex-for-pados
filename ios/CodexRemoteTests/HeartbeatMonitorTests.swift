import XCTest
@testable import CodexRemote

@MainActor
final class HeartbeatMonitorTests: XCTestCase {
    func test_twoConsecutiveMisses_triggersUnhealthy() async throws {
        let results = ResultScript([true, false, true, false, false])  // 第 4、5 次连续 miss
        let counter = Counter()
        let m = HeartbeatMonitor(
            config: .init(interval: .seconds(10), missThreshold: 2),
            probe: { await results.next() },
            onUnhealthy: { await counter.increment() },
            sleep: { _ in await Task.yield() })
        m.start()
        try await waitUntil { await results.consumed >= 5 }
        m.stop()
        let unhealthy = await counter.value
        XCTAssertEqual(unhealthy, 1, "仅在连续 2 次 miss 时判死一次，单次 miss 不判死")
    }

    func test_background_pausesProbes() async throws {
        let results = ResultScript(Array(repeating: true, count: 100))
        let m = HeartbeatMonitor(config: .init(interval: .seconds(10), missThreshold: 2),
                                 probe: { await results.next() },
                                 onUnhealthy: {}, sleep: { _ in await Task.yield() })
        m.start()
        try await waitUntil { await results.consumed >= 1 }
        m.setForeground(false)
        let snapshot = await results.consumed
        try? await Task.sleep(for: .milliseconds(50))
        let afterPause = await results.consumed
        XCTAssertEqual(afterPause, snapshot, "后台不再消耗探针")
    }

    func test_acceleratedProbe_singleMiss_doesNotTriggerUnhealthy() async throws {
        let results = ResultScript([true, false])
        let counter = Counter()
        let m = HeartbeatMonitor(config: .init(minimumAcceleratedProbeInterval: .zero),
                                 probe: { await results.next() },
                                 onUnhealthy: { await counter.increment() },
                                 sleep: { _ in try? await Task.sleep(for: .seconds(3600)) })
        m.start()
        try await waitUntil { await results.consumed == 1 }
        m.requestAcceleratedProbe()
        try await waitUntil { await results.consumed == 2 }
        m.stop()
        let unhealthy = await counter.value
        XCTAssertEqual(unhealthy, 0, "加速提示的单次 miss 也必须服从连续 miss 阈值")
    }

    func test_acceleratedProbeBurstCoalesces() async throws {
        let counter = Counter()
        let m = HeartbeatMonitor(config: .init(minimumAcceleratedProbeInterval: .zero),
                                 probe: { await counter.increment(); return true },
                                 onUnhealthy: {},
                                 sleep: { _ in try? await Task.sleep(for: .seconds(3600)) })
        m.start()
        try await waitUntil { await counter.value == 1 }
        for _ in 0..<100 { m.requestAcceleratedProbe() }
        try await waitUntil { await counter.value == 2 }
        try? await Task.sleep(for: .milliseconds(50))
        m.stop()
        let finalProbeCount = await counter.value
        XCTAssertEqual(finalProbeCount, 2, "提示突发只能合并成一个额外探针")
    }

    func test_acceleratedProbeSignalsAcrossProbeCompletionRespectMinimumInterval() async throws {
        let clock = ManualHeartbeatClock()
        let probes = GatedProbe()
        let m = HeartbeatMonitor(
            config: .init(interval: .seconds(10), inactiveInterval: .seconds(60),
                          missThreshold: 2, minimumAcceleratedProbeInterval: .seconds(10)),
            probe: { await probes.run() },
            onUnhealthy: {},
            sleep: { _ in try? await Task.sleep(for: .seconds(3600)) },
            now: { clock.now })

        m.start()
        try await waitUntil { await probes.count == 1 }
        for _ in 0..<20 { m.requestAcceleratedProbe() } // 第一探针仍在执行。
        await probes.releaseOne()
        try? await Task.sleep(for: .milliseconds(30))
        for _ in 0..<20 { m.requestAcceleratedProbe() } // 第一探针已完成。
        try? await Task.sleep(for: .milliseconds(30))
        let countBeforeMinimumInterval = await probes.count
        XCTAssertEqual(countBeforeMinimumInterval, 1, "最短间隔内持续 peer-left 不得按 RPC 速度追加探针")

        clock.advance(by: .seconds(10))
        m.requestAcceleratedProbe()
        try await waitUntil { await probes.count == 2 }
        for _ in 0..<20 { m.requestAcceleratedProbe() } // 第二探针执行期间继续攻击。
        await probes.releaseOne()
        try? await Task.sleep(for: .milliseconds(30))
        let finalCount = await probes.count
        XCTAssertEqual(finalCount, 2, "每个最短间隔至多允许一个加速探针")
        m.stop()
    }

    func test_inactiveUsesLongIntervalAndActivationProbesOnce() async throws {
        let probes = Counter()
        let sleeps = DurationRecorder()
        let m = HeartbeatMonitor(
            config: .init(interval: .seconds(10), inactiveInterval: .seconds(60), missThreshold: 2),
            probe: { await probes.increment(); return true },
            onUnhealthy: {},
            sleep: { duration in await sleeps.recordAndPark(duration) })
        m.setTabActive(false)
        m.start()
        try await waitUntil { await sleeps.values.count >= 1 }
        let firstSleep = await sleeps.values.first
        let inactiveProbeCount = await probes.value
        XCTAssertEqual(firstSleep, .seconds(60))
        XCTAssertEqual(inactiveProbeCount, 0, "非活动 tab 启动心跳时不应立即探测")

        m.setTabActive(true)
        try await waitUntil { await probes.value == 1 }
        try await waitUntil { await sleeps.values.contains(.seconds(10)) }
        try? await Task.sleep(for: .milliseconds(30))
        m.stop()
        let activeProbeCount = await probes.value
        XCTAssertEqual(activeProbeCount, 1, "切为活动 tab 只补一个立即探针")
    }

    func test_inactiveTabIgnoresAcceleratedProbeSignals() async throws {
        let probes = Counter()
        let sleeps = DurationRecorder()
        let m = HeartbeatMonitor(
            config: .init(interval: .seconds(10), inactiveInterval: .seconds(60),
                          minimumAcceleratedProbeInterval: .zero),
            probe: { await probes.increment(); return true },
            onUnhealthy: {},
            sleep: { duration in await sleeps.recordAndPark(duration) })
        m.setTabActive(false)
        m.start()
        try await waitUntil { await sleeps.values.contains(.seconds(60)) }

        for _ in 0..<100 { m.requestAcceleratedProbe() }
        try? await Task.sleep(for: .milliseconds(50))
        m.stop()

        let finalProbeCount = await probes.value
        XCTAssertEqual(finalProbeCount, 0,
                       "未认证 peer-left 不得让非活动 tab 绕过 60 秒探活下限")
    }

    func test_afterDeath_start_resumesLoop() async throws {
        let results = ResultScript(Array(repeating: false, count: 200))  // 恒 miss
        let m = HeartbeatMonitor(config: .init(interval: .seconds(10), missThreshold: 2),
                                 probe: { await results.next() },
                                 onUnhealthy: {}, sleep: { _ in await Task.yield() })
        m.start()
        try await waitUntil { await results.consumed >= 2 }
        let atDeath = await results.consumed
        m.start()
        try await waitUntil { await results.consumed > atDeath }
        m.stop()
        let resumed = await results.consumed
        XCTAssertGreaterThan(resumed, atDeath, "判死后 start() 应重启探测循环")
    }

    func test_foregroundResume_restartsLoopAndProbesOnce() async throws {
        let results = ResultScript(Array(repeating: true, count: 200))
        let m = HeartbeatMonitor(config: .init(interval: .seconds(10), missThreshold: 2),
                                 probe: { await results.next() },
                                 onUnhealthy: {}, sleep: { _ in await Task.yield() })
        m.start()
        try await waitUntil { await results.consumed >= 1 }
        m.setForeground(false)
        try? await Task.sleep(for: .milliseconds(20))
        let paused = await results.consumed
        m.setForeground(true)
        try await waitUntil { await results.consumed > paused }
        m.stop()
        let afterResume = await results.consumed
        XCTAssertGreaterThan(afterResume, paused, "回前台应恢复循环并补发探针")
    }

    // MARK: - #11：回前台唯一受跟踪探测（非双探针）+ 单次 miss 不判死

    /// 回前台只应发**一次**受跟踪探测（并入可取消 loop 首轮），而非「loop 首轮 + 游离
    /// `Task{probeOnce}`」双探针。用「阻塞式 sleep」把 loop 卡在首轮后，令探测数可数：
    /// 修复后每次前台 loop 启动恰 +1；旧实现的游离 probeOnce 会再 +1（双探）。
    func test_foregroundResume_singleTrackedProbe_notDouble() async throws {
        let count = Counter()
        let m = HeartbeatMonitor(
            config: .init(interval: .seconds(10), missThreshold: 2),
            probe: { await count.increment(); return true },
            onUnhealthy: {},
            sleep: { _ in try? await Task.sleep(for: .seconds(3600)) })  // 首轮后park，可被取消
        m.start()
        try await waitUntil { await count.value >= 1 }
        try? await Task.sleep(for: .milliseconds(30))
        let afterStart = await count.value
        XCTAssertEqual(afterStart, 1, "start 后 loop 首轮恰探一次")

        m.setForeground(false)                       // 取消 park 中的 loop
        try? await Task.sleep(for: .milliseconds(20))
        let paused = await count.value

        m.setForeground(true)                        // 回前台：应恰再探一次（并入 loop 首轮）
        try await waitUntil { await count.value > paused }
        try? await Task.sleep(for: .milliseconds(50)) // 给游离探针（若存在）充分执行窗口
        m.stop()
        let afterResume = await count.value
        XCTAssertEqual(afterResume, paused + 1,
                       "回前台应仅发一次受跟踪探测，游离 probeOnce 双探针即 +2（RED）")
    }

    /// 回前台后的探测须走带 `missThreshold` 计数的 loop，而非游离 `probeOnce`
    /// （后者任何单次 miss 即 onUnhealthy，绕过阈值）。把 `missThreshold` 设到高于本用例
    /// loop 累计 miss 数，令 loop 永不达阈值——此时若仍判死，必来自绕过阈值的游离探针。
    func test_foregroundResume_singleMiss_doesNotTriggerUnhealthy() async throws {
        let counter = Counter()
        let m = HeartbeatMonitor(
            config: .init(interval: .seconds(10), missThreshold: 3),  // 高于本用例 loop 累计 miss(2)
            probe: { false },                                          // 恒 miss
            onUnhealthy: { await counter.increment() },
            sleep: { _ in try? await Task.sleep(for: .seconds(3600)) })  // 首轮后park，可被取消
        m.start()                                    // loop 首轮 miss → cm=1 → park（未达阈值）
        try? await Task.sleep(for: .milliseconds(30))
        m.setForeground(false)                       // 取消 park 中的 loop
        try? await Task.sleep(for: .milliseconds(20))
        m.setForeground(true)                        // loop 首轮 miss → cm=2 → park（仍<3，不判死）
        try? await Task.sleep(for: .milliseconds(50)) // 给游离探针（若存在）充分执行窗口
        m.stop()
        let deaths = await counter.value
        XCTAssertEqual(deaths, 0,
                       "回前台单次 miss 不得判死（loop 未达阈值）；游离 probeOnce 绕过阈值即 +1（RED）")
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("waitUntil 超时")
    }
}

actor ResultScript {
    private var queue: [Bool]; private(set) var consumed = 0
    init(_ r: [Bool]) { queue = r }
    func next() -> Bool { consumed += 1; return queue.isEmpty ? true : queue.removeFirst() }
}

actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

actor DurationRecorder {
    private(set) var values: [Duration] = []
    func recordAndPark(_ duration: Duration) async {
        values.append(duration)
        try? await Task.sleep(for: .seconds(3600))
    }
}

final class ManualHeartbeatClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    var now: ContinuousClock.Instant {
        lock.withLock { instant }
    }
    func advance(by duration: Duration) {
        lock.withLock { instant = instant.advanced(by: duration) }
    }
}

actor GatedProbe {
    private(set) var count = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run() async -> Bool {
        count += 1
        await withCheckedContinuation { waiters.append($0) }
        return true
    }

    func releaseOne() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume()
    }
}
