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
