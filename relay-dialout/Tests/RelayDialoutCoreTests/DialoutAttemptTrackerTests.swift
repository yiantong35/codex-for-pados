import Testing
@testable import RelayDialoutCore

@Test func attemptTrackerReportsHealthAndTerminalReason() {
    let healthy = DialoutAttemptTracker()
    healthy.markHealthy()
    #expect(healthy.outcome == .closed(wasHealthy: true))

    let terminal = DialoutAttemptTracker()
    terminal.markHealthy()
    terminal.markTerminal(.trustRejected)
    terminal.markTerminal(.bridgeFailed)
    #expect(terminal.outcome == .terminal(.trustRejected))
}
