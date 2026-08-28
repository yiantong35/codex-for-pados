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

// MARK: - daemon-crash-detection：三信号幂等汇合（terminationHandler + SIGPIPE 免疫 + 写失败防抖）

/// 线程安全回调计数器（terminationHandler 在 Foundation 后台线程、drainWrites 在 writerQueue 回调）。
private final class CallbackCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

/// 有界等待条件成立（仅测试侧短轮询，生产零轮询）；超时即断言失败。
private func waitUntil(timeout: Duration = .seconds(5),
                       _ condition: @escaping @Sendable () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(condition(), "等待条件超时(\(timeout))")
}

/// ① daemon 被外部 kill -9：onAbnormalExit 恰好回调一次；测试内忽略 SIGPIPE 后
/// 向死进程 stdin 写不崩（EPIPE 走 throwing catch 可捕获）、防抖不二次回调。
@Test func externalKillReportsAbnormalExitExactlyOnce() async throws {
    signal(SIGPIPE, SIG_IGN)   // 与生产 main.swift 同款进程级免疫；对其余测试无副作用
    let callbacks = CallbackCounter()
    let bridge = DaemonBridge(codexPath: "/bin/sleep", arguments: ["300"],
                              onAbnormalExit: { callbacks.increment() })
    try bridge.start()
    let pid = bridge.pid
    #expect(pid > 0)
    kill(pid, SIGKILL)                                  // 外部杀死,模拟 daemon 崩溃
    try await waitUntil { callbacks.count == 1 }        // terminationHandler 异步触发
    // 死进程 stdin 写入:不得崩溃(SIGPIPE 已忽略→EPIPE→drainWrites catch),防抖不二次回调
    _ = bridge.write("hello-after-death")
    try await Task.sleep(for: .milliseconds(200))
    #expect(callbacks.count == 1)
    bridge.terminate()          // 已死进程 guard isRunning no-op,幂等
    bridge.waitForTermination()
}

/// ② 孙进程继承 stdout 写端且父先退出：EOF 缺席（路径③），terminationHandler 仍是权威死亡信号。
/// 孙进程为无害 /bin/sleep 30,测试不杀它(进程安全铁律:零宽匹配 kill),自会退出。
@Test func grandchildHoldingStdoutStillReportsExit() async throws {
    let callbacks = CallbackCounter()
    let bridge = DaemonBridge(codexPath: "/bin/sh",
                              arguments: ["-c", "(sleep 30 &); sleep 0.2"],
                              onAbnormalExit: { callbacks.increment() })
    try bridge.start()
    // 父 sh 约 0.2s 后自然退出;孙 sleep 30 仍持有 stdout 写端 → EOF 不来,只有 terminationHandler
    try await waitUntil { callbacks.count == 1 }
    #expect(callbacks.count == 1)
    bridge.terminate()
    bridge.waitForTermination()
}

/// ③ 主动 terminate()：expectedTermination 先置位后杀，terminationHandler 静默，零误报。
/// （回收行为本体已由既有 terminateReapsSpawnedChildNoZombie 覆盖,此处只盯零回调。）
@Test func deliberateTerminateDoesNotReportAbnormalExit() async throws {
    let callbacks = CallbackCounter()
    let bridge = DaemonBridge(codexPath: "/bin/sleep", arguments: ["300"],
                              onAbnormalExit: { callbacks.increment() })
    try bridge.start()
    #expect(bridge.isRunning)
    bridge.terminate()
    bridge.waitForTermination()
    #expect(!bridge.isRunning)
    try await Task.sleep(for: .milliseconds(300))   // terminationHandler 异步;留窗确认其间无误报
    #expect(callbacks.count == 0)
}

/// ④ 双源防抖恰好一次（terminationHandler + 写失败 catch）+ EOF 既有链路回归（incoming 流仍正常 finish）。
@Test func debounceAcrossSourcesAndEOFStillFinishes() async throws {
    signal(SIGPIPE, SIG_IGN)
    let callbacks = CallbackCounter()
    let bridge = DaemonBridge(codexPath: "/bin/sleep", arguments: ["300"],
                              onAbnormalExit: { callbacks.increment() })
    try bridge.start()
    let stream = bridge.incoming
    let finished = Task { for await _ in stream {}; return true }   // EOF → finish 才返回
    kill(bridge.pid, SIGKILL)
    try await waitUntil { callbacks.count >= 1 }
    // 第二源:向死 stdin 写触发 drainWrites catch → 过同一防抖标志,不得二次回调
    _ = bridge.write("late")
    try await Task.sleep(for: .milliseconds(200))
    #expect(callbacks.count == 1)
    // EOF 回归:sleep 死后 stdout 写端关闭 → 既有 readabilityHandler 空 chunk → 流正常结束
    #expect(await finished.value)
    bridge.terminate()
    bridge.waitForTermination()
}
