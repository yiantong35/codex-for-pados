import Testing
import Foundation
@testable import RelayDialoutCore

/// terminate() 应回收自己 spawn 的子进程（补 waitUntilExit 前，terminate 只发信号即返回，
/// 子进程尚未退出 → isRunning 仍为 true）。用无害长驻 stub `/bin/sleep 300` 精确验证：
/// 只对 ProxyBridge 自己持有的 `process` 句柄（精确 PID）操作，绝不按名/宽匹配 kill。
@Test func terminateReapsSpawnedChildNoZombie() throws {
    // 注入 /bin/sleep 300 作无害长驻子进程 stub（arguments 注入点仅测试用，不改生产路径）。
    let sock = "/tmp/relay-t5-proxybridge-\(ProcessInfo.processInfo.globallyUniqueString).sock"
    let bridge = ProxyBridge(codexPath: "/bin/sleep", arguments: ["300"], sockPath: sock)

    try bridge.start()
    let pid = bridge.pid
    #expect(pid > 0)               // 确有自己 spawn 的子进程
    #expect(bridge.isRunning)      // 长驻 stub 确在运行

    bridge.terminate()

    // waitUntilExit 返回后子进程已退出并被 reap（无僵尸）；仍是同一自己持有的句柄，未另找进程。
    #expect(!bridge.isRunning)
    #expect(bridge.pid == pid)
}
