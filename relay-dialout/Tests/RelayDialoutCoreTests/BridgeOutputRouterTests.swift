import Testing
import Foundation
@testable import RelayDialoutCore

private final class RoutedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ line: String) {
        lock.lock()
        storage.append(line)
        lock.unlock()
    }

    var value: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class ExitFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var exited = false

    func mark() { lock.lock(); exited = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return exited }
}

@Test func detachedOutputIsDroppedAndNeverReplayed() {
    let lines = RoutedLines()
    let router = BridgeOutputRouter(stream: { AsyncStream { _ in } }, onBridgeExit: {})

    router.route("while-disconnected")
    _ = router.attach { lines.append($0) }
    router.route("after-reconnect")

    #expect(lines.value == ["after-reconnect"])
}

@Test func staleDetachCannotRemoveNewConnectionSink() {
    let first = RoutedLines()
    let second = RoutedLines()
    let router = BridgeOutputRouter(stream: { AsyncStream { _ in } }, onBridgeExit: {})
    let oldAttachment = router.attach { first.append($0) }
    _ = router.attach { second.append($0) }

    router.detach(oldAttachment)
    router.route("new-owner")

    #expect(first.value.isEmpty)
    #expect(second.value == ["new-owner"])
}

@Test func unexpectedBridgeEOFReportsTerminalExit() async {
    let exited = ExitFlag()
    let router = BridgeOutputRouter(
        stream: {
            AsyncStream { continuation in continuation.finish() }
        },
        onBridgeExit: { exited.mark() }
    )
    router.start()
    for _ in 0..<1_000 where !exited.value {
        await Task.yield()
    }
    #expect(exited.value)
}

/// `stop()` 必须抑制「流结束」对 `onBridgeExit` 的上报（置 stopping → streamFinished 不报）。
/// 这是 `recycleCurrent()` 走 `router.stop()` 前置以保 dialout 存活的关键守卫；若实现把
/// `lifecycle.shutdown()` 放到 `router.stop()` 之前，本测试会失败（误报 dialout 停机）。
@Test func stopSuppressesExitReportWhenStreamFinishes() async {
    let exited = ExitFlag()
    let router = BridgeOutputRouter(
        stream: { AsyncStream { _ in } },   // 永不结束的流：仅靠 stop() 触发其 finish 路径
        onBridgeExit: { exited.mark() }
    )
    router.start()
    await Task.yield()   // 让 stream task 开始 await 下一个元素
    router.stop()        // cancel 任务 → for-await 结束 → streamFinished() 见 stopping=true → 不上报
    for _ in 0..<1_000 { await Task.yield() }
    #expect(!exited.value)   // 主动 stop() 不应触发 dialout 停机上报
}
