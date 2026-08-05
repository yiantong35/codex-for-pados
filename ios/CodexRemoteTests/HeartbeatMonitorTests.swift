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

    func test_probeOnce_singleMiss_triggersUnhealthy() async {
        let counter = Counter()
        let m = HeartbeatMonitor(config: .init(), probe: { false },
                                 onUnhealthy: { await counter.increment() }, sleep: { _ in })
        await m.probeOnce()
        let unhealthy = await counter.value
        XCTAssertEqual(unhealthy, 1)
    }

    func test_probeOnce_hit_ignored() async {
        let counter = Counter()
        let m = HeartbeatMonitor(config: .init(), probe: { true },
                                 onUnhealthy: { await counter.increment() }, sleep: { _ in })
        await m.probeOnce()
        let unhealthy = await counter.value
        XCTAssertEqual(unhealthy, 0)
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
