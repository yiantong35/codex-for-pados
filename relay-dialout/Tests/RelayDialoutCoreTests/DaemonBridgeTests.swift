import Testing
import Foundation
@testable import RelayDialoutCore

/// 生产参数必须指向 spawn `codex app-server --listen stdio://`（单客户端裸行 JSON，无监听端口），
/// 而非旧的 `app-server proxy --sock <path>`（桥接一个不存在的 control.sock=两个月悬案根因）。
/// 用只读 resolvedArguments 断言，不必真的 spawn daemon。
@Test func productionArgumentsPointAtStdioListen() {
    let bridge = DaemonBridge(codexPath: "codex")   // 不注入 arguments → 走生产参数
    #expect(bridge.resolvedArguments == ["app-server", "--listen", "stdio://"])
}

@Test func bareExecutableNameResolvesThroughPATH() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("daemon-path-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appendingPathComponent("codex-test")
    try Data("#!/bin/sh\nexec /bin/sleep 300\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

    let bridge = DaemonBridge(codexPath: "codex-test", arguments: [],
                              environment: ["PATH": directory.path])
    try bridge.start()
    #expect(bridge.isRunning)
    bridge.terminate()
    bridge.waitForTermination()
}

@Test func missingBareExecutableFailsBeforeProcessLaunch() {
    let bridge = DaemonBridge(codexPath: "definitely-not-installed",
                              environment: ["PATH": "/nonexistent"])
    #expect(throws: DaemonBridgeError.executableNotFound("definitely-not-installed")) {
        try bridge.start()
    }
}

@Test func stdinWriterIsBoundedAndPreservesOrder() async throws {
    let bridge = DaemonBridge(codexPath: "/bin/cat", arguments: [],
                              maximumPendingWriteBytes: 64)
    try bridge.start()
    let stream = bridge.incoming
    let received = Task { () -> [String] in
        var lines: [String] = []
        for await line in stream {
            lines.append(line)
            if lines.count == 3 { break }
        }
        return lines
    }

    #expect(bridge.write("one"))
    #expect(bridge.write("two"))
    #expect(bridge.write("three"))
    #expect(await received.value == ["one", "two", "three"])
    #expect(!bridge.write(String(repeating: "x", count: 64)))
    bridge.terminate()
    bridge.waitForTermination()
}

/// terminate() 应非阻塞地发起回收，调用方可在 EventLoop 外显式等待子进程被 reap。
/// 只对 DaemonBridge 自己持有的 `process` 句柄（精确 PID）操作，绝不按名/宽匹配 kill。
@Test func terminateReapsSpawnedChildNoZombie() throws {
    // 注入 /bin/sleep 300 作无害长驻子进程 stub（arguments 注入点仅测试用，不改生产路径）。
    let bridge = DaemonBridge(codexPath: "/bin/sleep", arguments: ["300"])

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
    let bridge = DaemonBridge(
        codexPath: "/bin/sh",
        arguments: ["-c", "trap '' TERM; exec /bin/sleep 300"],
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

/// D3:生产默认子进程工作目录 = 用户家目录(中性、稳定、非源码目录、无写副作用),
/// 且绝非拨出程序启动目录——旧缺陷:子进程继承 .../relay-dialout 源码目录,新会话诡异落此。
@Test func productionWorkingDirectoryIsUserHome() {
    let bridge = DaemonBridge(codexPath: "codex")   // 不注入 → 走生产默认
    let home = FileManager.default.homeDirectoryForCurrentUser
    #expect(bridge.resolvedWorkingDirectory == home)
    // 旧缺陷:子进程继承拨出程序启动目录(.../relay-dialout 源码目录),新会话诡异落此。
    // 仅当启动目录确非家目录时才断言「解析目录 ≠ 启动目录」——避免恰好从 $HOME 执行 swift test 时假红。
    let launchDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL
    if launchDir != home.standardizedFileURL {
        #expect(bridge.resolvedWorkingDirectory.standardizedFileURL != launchDir)
    }
}

/// 注入覆盖便于单测断言(不改生产调用路径)。
@Test func injectedWorkingDirectoryOverridesDefault() {
    let temp = FileManager.default.temporaryDirectory
        .appendingPathComponent("daemon-cwd-\(UUID().uuidString)", isDirectory: true)
    let bridge = DaemonBridge(codexPath: "codex", workingDirectory: temp)
    #expect(bridge.resolvedWorkingDirectory == temp)
}
