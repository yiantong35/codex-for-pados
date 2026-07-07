import XCTest
@testable import CodexRemote

final class DaemonBootstrapTests: XCTestCase {
    func testParseCleanJSON() throws {
        let out = #"{"status":"alreadyRunning","managedCodexVersion":"0.140.0","socketPath":"/Users/tj/.codex/app-server-control/app-server-control.sock","cliVersion":"0.142.1"}"#
        let r = try DaemonBootstrap.parse(out)
        XCTAssertEqual(r.status, "alreadyRunning")
        XCTAssertEqual(r.socketPath, "/Users/tj/.codex/app-server-control/app-server-control.sock")
    }
    func testParseWithLeadingNoise() throws {
        let out = "some login banner\nwarning: xyz\n{\"status\":\"started\",\"socketPath\":\"/tmp/x.sock\"}\n"
        let r = try DaemonBootstrap.parse(out)
        XCTAssertEqual(r.status, "started")
        XCTAssertEqual(r.socketPath, "/tmp/x.sock")
    }
    func testParseGarbageThrows() {
        XCTAssertThrowsError(try DaemonBootstrap.parse("command not found: codex\n"))
    }
    func testCommandsCarryPathAndSubcommand() {
        XCTAssertTrue(DaemonBootstrap.startCommand.contains("codex app-server daemon start"))
        XCTAssertTrue(DaemonBootstrap.startCommand.contains("CODEX_INSTALL_DIR"))
        let proxy = DaemonBootstrap.proxyCommand(sockPath: "/tmp/x.sock")
        XCTAssertTrue(proxy.contains("codex app-server proxy --sock /tmp/x.sock"))
        XCTAssertTrue(proxy.contains("CODEX_INSTALL_DIR"))
    }
}
