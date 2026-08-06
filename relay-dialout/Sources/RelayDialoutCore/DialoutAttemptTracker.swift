import Foundation

public final class DialoutAttemptTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var healthy = false
    private var terminalReason: DialoutStopReason?

    public init() {}

    public func markHealthy() {
        lock.lock()
        healthy = true
        lock.unlock()
    }

    public func markTerminal(_ reason: DialoutStopReason) {
        lock.lock()
        if terminalReason == nil { terminalReason = reason }
        lock.unlock()
    }

    public var outcome: DialoutAttemptOutcome {
        lock.lock()
        defer { lock.unlock() }
        if let terminalReason { return .terminal(terminalReason) }
        return .closed(wasHealthy: healthy)
    }
}
