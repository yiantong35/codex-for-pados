import Testing
@testable import RelayDialoutCore

private enum SupervisorStubError: Error { case connectFailed }

private actor AttemptScript {
    enum Step: Sendable {
        case failure
        case outcome(DialoutAttemptOutcome)
        case waitForCancellation
    }

    private var steps: [Step]
    private(set) var attempts = 0
    private(set) var startedWaiting = false

    init(_ steps: [Step]) { self.steps = steps }

    func connect() async throws -> DialoutAttemptOutcome {
        attempts += 1
        let step = steps.removeFirst()
        switch step {
        case .failure:
            throw SupervisorStubError.connectFailed
        case .outcome(let outcome):
            return outcome
        case .waitForCancellation:
            startedWaiting = true
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return .closed(wasHealthy: false)
        }
    }
}

private actor SupervisorRecorder {
    private(set) var delays: [UInt64] = []
    private(set) var shutdowns = 0
    private(set) var blockingSleepStarted = false

    func sleep(_ nanoseconds: UInt64) async throws {
        delays.append(nanoseconds)
    }

    func shutdown() { shutdowns += 1 }

    func blockingSleep(_ nanoseconds: UInt64) async throws {
        delays.append(nanoseconds)
        blockingSleepStarted = true
        try await Task.sleep(nanoseconds: 60_000_000_000)
    }
}

private func makeSupervisor(
    script: AttemptScript,
    recorder: SupervisorRecorder,
    policy: DialoutRetryPolicy = .init(
        baseDelayNanoseconds: 100,
        maxDelayNanoseconds: 800,
        jitterFraction: 0
    ),
    randomUnit: @escaping @Sendable () -> Double = { 0.5 }
) -> DialoutSupervisor {
    DialoutSupervisor(
        policy: policy,
        connector: { try await script.connect() },
        sleep: { try await recorder.sleep($0) },
        randomUnit: randomUnit,
        onShutdown: { await recorder.shutdown() }
    )
}

@Test func connectFailureAndRemoteCloseRetryUntilTerminalTrustFailure() async {
    let script = AttemptScript([
        .failure,
        .outcome(.closed(wasHealthy: false)),
        .outcome(.terminal(.trustRejected)),
    ])
    let recorder = SupervisorRecorder()
    let supervisor = makeSupervisor(script: script, recorder: recorder)

    let result = await supervisor.run()

    #expect(result == .trustRejected)
    #expect(await script.attempts == 3)
    #expect(await recorder.delays == [100, 200])
    #expect(await recorder.shutdowns == 1)
}

@Test func healthyHandshakeResetsBackoffBeforeNextReconnect() async {
    let script = AttemptScript([
        .outcome(.closed(wasHealthy: false)),
        .outcome(.closed(wasHealthy: false)),
        .outcome(.closed(wasHealthy: true)),
        .outcome(.terminal(.bridgeExited)),
    ])
    let recorder = SupervisorRecorder()
    let supervisor = makeSupervisor(script: script, recorder: recorder)

    let result = await supervisor.run()

    #expect(result == .bridgeExited)
    #expect(await recorder.delays == [100, 200, 100])
}

@Test func retryPolicyCapsDelayAndKeepsJitterWithinBounds() {
    let policy = DialoutRetryPolicy(
        baseDelayNanoseconds: 100,
        maxDelayNanoseconds: 400,
        jitterFraction: 0.25
    )

    #expect(policy.delayNanoseconds(attempt: 0, randomUnit: 0) == 75)
    #expect(policy.delayNanoseconds(attempt: 0, randomUnit: 1) == 125)
    #expect(policy.delayNanoseconds(attempt: 8, randomUnit: 0) == 300)
    #expect(policy.delayNanoseconds(attempt: 8, randomUnit: 1) == 400)

    let extreme = DialoutRetryPolicy(
        baseDelayNanoseconds: .max,
        maxDelayNanoseconds: .max,
        jitterFraction: 1
    )
    #expect(extreme.delayNanoseconds(attempt: 1, randomUnit: 1) == .max)
}

@Test func stopCancelsInFlightConnectionAndShutsDownOnce() async throws {
    let script = AttemptScript([.waitForCancellation])
    let recorder = SupervisorRecorder()
    let supervisor = makeSupervisor(script: script, recorder: recorder)
    let runTask = Task { await supervisor.run() }

    while await !script.startedWaiting {
        await Task.yield()
    }
    await supervisor.stop(.cancelled)

    #expect(await runTask.value == .cancelled)
    #expect(await recorder.delays.isEmpty)
    #expect(await recorder.shutdowns == 1)
}

@Test func stopCancelsBackoffSleepWithoutStartingAnotherAttempt() async {
    let script = AttemptScript([.failure])
    let recorder = SupervisorRecorder()
    let supervisor = DialoutSupervisor(
        policy: .init(baseDelayNanoseconds: 100, maxDelayNanoseconds: 100, jitterFraction: 0),
        connector: { try await script.connect() },
        sleep: { try await recorder.blockingSleep($0) },
        onShutdown: { await recorder.shutdown() }
    )
    let runTask = Task { await supervisor.run() }

    while !(await recorder.blockingSleepStarted) {
        await Task.yield()
    }
    await supervisor.stop(.cancelled)

    #expect(await runTask.value == .cancelled)
    #expect(await script.attempts == 1)
    #expect(await recorder.shutdowns == 1)
}

@Test(arguments: [DialoutStopReason.trustRejected, .bridgeExited, .bridgeFailed])
func terminalOutcomesNeverRetry(_ reason: DialoutStopReason) async {
    let script = AttemptScript([.outcome(.terminal(reason))])
    let recorder = SupervisorRecorder()
    let supervisor = makeSupervisor(script: script, recorder: recorder)

    #expect(await supervisor.run() == reason)
    #expect(await script.attempts == 1)
    #expect(await recorder.delays.isEmpty)
}
