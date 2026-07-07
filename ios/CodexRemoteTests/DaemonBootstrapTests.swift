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
        // sockPath 现单引号包裹以抗空格/元字符（#4）。
        XCTAssertTrue(proxy.contains("codex app-server proxy --sock '/tmp/x.sock'"))
        XCTAssertTrue(proxy.contains("CODEX_INSTALL_DIR"))
    }

    // #4：sockPath 必须单引号包裹，普通路径也不例外。
    func testProxyQuotesNormalPath() {
        let proxy = DaemonBootstrap.proxyCommand(sockPath: "/tmp/x.sock")
        XCTAssertTrue(proxy.contains("--sock '/tmp/x.sock'"),
                      "普通路径应被单引号包裹，实际：\(proxy)")
    }

    // #4：含空格的路径必须作为单个 shell 参数（单引号包裹）。
    func testProxyQuotesPathWithSpace() {
        let proxy = DaemonBootstrap.proxyCommand(sockPath: "/My Files/x.sock")
        XCTAssertTrue(proxy.contains("--sock '/My Files/x.sock'"),
                      "含空格路径应被单引号包裹，实际：\(proxy)")
    }

    // #4：含单引号的路径必须用 '\'' 技巧转义，保持单个合法 shell 参数。
    func testProxyEscapesSingleQuoteInPath() {
        let proxy = DaemonBootstrap.proxyCommand(sockPath: "/a'b/x.sock")
        // /a'b/x.sock → '/a'\''b/x.sock'
        XCTAssertTrue(proxy.contains("--sock '/a'\\''b/x.sock'"),
                      "含单引号路径应用 '\\'' 转义，实际：\(proxy)")
    }
}
