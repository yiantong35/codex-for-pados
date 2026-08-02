import XCTest
@testable import CodexRemote

@MainActor
final class HeartbeatMonitorTests: XCTestCase {
    // 连续错过 2 次才判死；单次错过（之后恢复）不判死。
    func test_twoConsecutiveMisses_triggersUnhealthy() async throws {
        let results = ResultScript([true, false, true, false, false])  // 第 4、5 次连续 miss
        let counter = Counter()
        let m = HeartbeatMonitor(
            config: .init(interval: .seconds(10), missThreshold: 2),
            probe: { await results.next() },
            onUnhealthy: { await counter.increment() },
            sleep: { _ in await Task.yield() })                       // 注入 no-op sleep
        m.start()
        try await waitUntil { await results.consumed >= 5 }
        m.stop()
        let unhealthy = await counter.value
        XCTAssertEqual(unhealthy, 1, "仅在连续 2 次 miss 时判死一次，单次 miss 不判死")
    }

    // 后台暂停：setForeground(false) 后不再发探针。
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

    // probeOnce：单次 miss 即判死（peer-left 核实语义）。
    func test_probeOnce_singleMiss_triggersUnhealthy() async {
        let counter = Counter()
        let m = HeartbeatMonitor(config: .init(), probe: { false },
                                 onUnhealthy: { await counter.increment() },
                                 sleep: { _ in })
        await m.probeOnce()
        let unhealthy = await counter.value
        XCTAssertEqual(unhealthy, 1)
    }

    // probeOnce：有回响则忽略（防伪造降级）。
    func test_probeOnce_hit_ignored() async {
        let counter = Counter()
        let m = HeartbeatMonitor(config: .init(), probe: { true },
                                 onUnhealthy: { await counter.increment() },
                                 sleep: { _ in })
        await m.probeOnce()
        let unhealthy = await counter.value
        XCTAssertEqual(unhealthy, 0)
    }

    /// 轮询条件直到为真或超时。（复用 ConnectionStoreTests.swift 内实现）
    private func waitUntil(timeout: TimeInterval = 3,
                          _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("waitUntil 超时")
    }
}

/// 脚本化探针结果，线程安全计数。
actor ResultScript {
    private var queue: [Bool]; private(set) var consumed = 0
    init(_ r: [Bool]) { queue = r }
    func next() -> Bool { consumed += 1; return queue.isEmpty ? true : queue.removeFirst() }
}

/// 线程安全计数器（onUnhealthy 判死计数）。
actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}
