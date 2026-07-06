import Testing
@testable import CodexRemote

struct ConnectionConfigLogicTests {
    @Test func sockPathDerivedFromUser() {
        #expect(ConnectionConfigView.sockPath(forUser: "alice")
                == "/Users/alice/.codex/app-server-control/app-server-control.sock")
    }
}
