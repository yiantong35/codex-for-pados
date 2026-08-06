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
