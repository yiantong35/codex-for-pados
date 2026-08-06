import Testing
import Foundation
@testable import RelayDialoutCore

@Test func bareExecutableNameResolvesThroughPATH() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("proxy-path-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appendingPathComponent("codex-test")
    try Data("#!/bin/sh\nexec /bin/sleep 300\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

    let bridge = ProxyBridge(codexPath: "codex-test", arguments: [], sockPath: "/tmp/unused",
                             environment: ["PATH": directory.path])
    try bridge.start()
    #expect(bridge.isRunning)
    bridge.terminate()
    bridge.waitForTermination()
}

@Test func missingBareExecutableFailsBeforeProcessLaunch() {
    let bridge = ProxyBridge(codexPath: "definitely-not-installed", sockPath: "/tmp/unused",
                             environment: ["PATH": "/nonexistent"])
    #expect(throws: ProxyBridgeError.executableNotFound("definitely-not-installed")) {
        try bridge.start()
    }
}

/// terminate() 应非阻塞地发起回收，调用方可在 EventLoop 外显式等待子进程被 reap。
@Test func terminateReapsSpawnedChildNoZombie() throws {
    // 注入 /bin/sleep 300 作无害长驻子进程 stub（arguments 注入点仅测试用，不改生产路径）。
    let sock = "/tmp/relay-t5-proxybridge-\(ProcessInfo.processInfo.globallyUniqueString).sock"
    let bridge = ProxyBridge(codexPath: "/bin/sleep", arguments: ["300"], sockPath: sock)

    try bridge.start()
    let pid = bridge.pid
    #expect(pid > 0)               // 确有自己 spawn 的子进程
    #expect(bridge.isRunning)      // 长驻 stub 确在运行

    let startedAt = ContinuousClock.now
    bridge.terminate()
    let elapsed = startedAt.duration(to: .now)
    #expect(elapsed < .milliseconds(100), "terminate 不得在调用线程等待子进程")
    bridge.waitForTermination()

    // 显式等待返回后子进程已退出并被 reap；仍是同一自己持有的句柄，未另找进程。
    #expect(!bridge.isRunning)
    #expect(bridge.pid == pid)
}

/// 忽略 SIGTERM 的子进程必须在有界宽限期后，仅按保存的 PID 收到 SIGKILL 并被 reap。
@Test func stubbornChildIsKilledAfterGracePeriod() throws {
    let sock = "/tmp/relay-t5-stubborn-\(ProcessInfo.processInfo.globallyUniqueString).sock"
    let bridge = ProxyBridge(
        codexPath: "/bin/sh",
        arguments: ["-c", "trap '' TERM; exec /bin/sleep 300"],
        sockPath: sock,
        terminationGracePeriod: .milliseconds(250)
    )

    try bridge.start()
    let pid = bridge.pid
    #expect(pid > 0)
    Thread.sleep(forTimeInterval: 0.05) // 等待 shell 安装 SIGTERM ignore disposition 并 exec sleep。
    let startedAt = ContinuousClock.now
    bridge.terminate()
    #expect(startedAt.duration(to: .now) < .milliseconds(100), "不得在调用线程等待 250ms 宽限期")
    bridge.terminate()
    bridge.waitForTermination()

    #expect(!bridge.isRunning)
    #expect(bridge.pid == pid)
    #expect(bridge.terminationSignal == SIGKILL)
}
