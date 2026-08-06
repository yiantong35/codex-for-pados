import Foundation

public enum DialoutStopReason: Sendable, Equatable {
    case cancelled
    case trustRejected
    case bridgeExited
    case bridgeFailed
}

public enum DialoutAttemptOutcome: Sendable, Equatable {
    case closed(wasHealthy: Bool)
    case terminal(DialoutStopReason)
}

public struct DialoutRetryPolicy: Sendable, Equatable {
    public let baseDelayNanoseconds: UInt64
    public let maxDelayNanoseconds: UInt64
    public let jitterFraction: Double

    public init(
        baseDelayNanoseconds: UInt64 = 500_000_000,
        maxDelayNanoseconds: UInt64 = 30_000_000_000,
        jitterFraction: Double = 0.2
    ) {
        let base = max(baseDelayNanoseconds, 1)
        self.baseDelayNanoseconds = base
        self.maxDelayNanoseconds = max(maxDelayNanoseconds, base)
        self.jitterFraction = min(max(jitterFraction, 0), 1)
    }

    public func delayNanoseconds(attempt: Int, randomUnit: Double) -> UInt64 {
        var nominal = baseDelayNanoseconds
        for _ in 0..<max(attempt, 0) {
            if nominal >= maxDelayNanoseconds / 2 {
                nominal = maxDelayNanoseconds
                break
            }
            nominal *= 2
        }

        let unit = min(max(randomUnit, 0), 1)
        let factor = (1 - jitterFraction) + (2 * jitterFraction * unit)
        let jittered = Double(nominal) * factor
        if jittered >= Double(maxDelayNanoseconds) { return maxDelayNanoseconds }
        return UInt64(jittered)
    }
}

public actor DialoutSupervisor {
    public typealias Connector = @Sendable () async throws -> DialoutAttemptOutcome
    public typealias Sleeper = @Sendable (UInt64) async throws -> Void

    private let policy: DialoutRetryPolicy
    private let connector: Connector
    private let sleep: Sleeper
    private let randomUnit: @Sendable () -> Double
    private let onShutdown: @Sendable () async -> Void

    private var requestedStop: DialoutStopReason?
    private var cancelInFlight: (@Sendable () -> Void)?
    private var isRunning = false

    public init(
        policy: DialoutRetryPolicy = .init(),
        connector: @escaping Connector,
        sleep: @escaping Sleeper = { try await Task.sleep(nanoseconds: $0) },
        randomUnit: @escaping @Sendable () -> Double = { Double.random(in: 0...1) },
        onShutdown: @escaping @Sendable () async -> Void
    ) {
        self.policy = policy
        self.connector = connector
        self.sleep = sleep
        self.randomUnit = randomUnit
        self.onShutdown = onShutdown
    }

    public func stop(_ reason: DialoutStopReason) {
        guard requestedStop == nil else { return }
        requestedStop = reason
        cancelInFlight?()
    }

    public func run() async -> DialoutStopReason {
        precondition(!isRunning, "DialoutSupervisor.run() may only be called once")
        isRunning = true

        let result = await runLoop()
        cancelInFlight = nil
        await onShutdown()
        isRunning = false
        return result
    }

    private func runLoop() async -> DialoutStopReason {
        var attempt = 0

        while true {
            if let requestedStop { return requestedStop }

            let outcome: DialoutAttemptOutcome?
            do {
                let task = Task { try await connector() }
                cancelInFlight = { task.cancel() }
                outcome = try await task.value
                cancelInFlight = nil
            } catch is CancellationError {
                cancelInFlight = nil
                return requestedStop ?? .cancelled
            } catch {
                cancelInFlight = nil
                outcome = nil
            }

            if let requestedStop { return requestedStop }
            if case .terminal(let reason) = outcome { return reason }
            if case .closed(wasHealthy: true) = outcome { attempt = 0 }

            let delay = policy.delayNanoseconds(attempt: attempt, randomUnit: randomUnit())
            attempt = min(attempt + 1, 63)
            do {
                let task = Task { try await sleep(delay) }
                cancelInFlight = { task.cancel() }
                try await task.value
                cancelInFlight = nil
            } catch {
                cancelInFlight = nil
                return requestedStop ?? .cancelled
            }
        }
    }
}
