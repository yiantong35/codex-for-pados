import Testing
import Foundation
@testable import RelayDialoutCore

/// 线程安全计数器，用于断言「主动回收不触发 onBridgeExit / onAbnormalExit」。
private final class CallbackCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

/// 「Already initialized」重连缺陷（app 被强杀后无法重连、需重启 relay-dialout）根治所需的可单测单元。
///
/// 根因：旧实现把 `DaemonBridge` 在 `main.swift` 顶层只建一次、`BridgeLifecycle.ensureStarted()` 幂等持有，
/// app-server daemon 启动后再也不死。iPad app 强杀（如 XCUITest teardown）重启后重连，重握手成功、重新
/// `initialize` 时命中**同一个已初始化 daemon** → `-32600 Already initialized`。
///
/// 语义：一次握手 = 一个新 iPad 会话 = 一个全新 app-server daemon。`beginSession()` 每次调用都精确回收旧
/// daemon（若有）并重新 spawn。`DaemonBridge` 是一次性对象，故每次会话都新建实例、绝不复用。
struct DialoutSessionBridgeTests {

    /// 记录每次 factory 创建出的 DaemonBridge，便于断言「旧 daemon 被回收、新 daemon 是不同实例」。
    private final class BridgeCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var _bridges: [DaemonBridge] = []
        func append(_ b: DaemonBridge) { lock.lock(); _bridges.append(b); lock.unlock() }
        var bridges: [DaemonBridge] { lock.lock(); defer { lock.unlock() }; return _bridges }
    }

    private func makeSleepFactory(_ collector: BridgeCollector)
        -> DialoutSessionBridge.DaemonFactory {
        { onAbnormalExit in
            let b = DaemonBridge(codexPath: "/bin/sleep", arguments: ["300"], onAbnormalExit: onAbnormalExit)
            collector.append(b)
            return b
        }
    }

    /// 重握手：第二次 beginSession 必须回收第一个 daemon（已初始化），并 spawn 一个**全新** daemon。
    /// 这正是让 iPad 重连后重新 initialize 命中全新会话、杜绝 -32600 的核心。
    @Test func beginSessionRecyclesDaemonOnRehandshake() throws {
        let collector = BridgeCollector()
        let sessionBridge = DialoutSessionBridge(
            daemonFactory: makeSleepFactory(collector), onBridgeExit: {})

        // 首次握手：spawn 会话 1。
        try sessionBridge.beginSession()
        let first = collector.bridges[0]
        #expect(first.isRunning)

        // 重握手：回收会话 1，重新 spawn 会话 2。
        try sessionBridge.beginSession()
        #expect(collector.bridges.count == 2)
        let second = collector.bridges[1]
        #expect(first !== second)                      // 不同 DaemonBridge 实例（一次性对象）。
        #expect(second.pid != first.pid)               // 不同进程（全新 daemon）。
        #expect(second.isRunning)
        first.waitForTermination()                     // 精确回收旧 daemon（等其 processQueue 完成 reap）。
        #expect(!first.isRunning)

        // 终态收口：当前（第 2）会话也应回收。
        sessionBridge.shutdownAll()
        sessionBridge.awaitTermination()
        #expect(!second.isRunning)
    }

    /// 启动失败必须冒泡（不吞），且**不发布**失败会话——调用方可据此 fail-closed 关连接。
    @Test func beginSessionBubblesStartFailureAndDoesNotPublish() throws {
        let sessionBridge = DialoutSessionBridge(
            daemonFactory: { onAbnormalExit in DaemonBridge(codexPath: "/nonexistent/stub", onAbnormalExit: onAbnormalExit) },
            onBridgeExit: {})
        #expect(throws: (any Error).self) { try sessionBridge.beginSession() }
        #expect(sessionBridge.bridge == nil)     // 失败不发布 current
        #expect(sessionBridge.router == nil)
    }

    /// 从未建立会话就 shutdownAll：无副作用、不崩。
    @Test func shutdownAllWithoutSessionIsNoOp() {
        let sessionBridge = DialoutSessionBridge(daemonFactory: makeSleepFactory(BridgeCollector()), onBridgeExit: {})
        sessionBridge.shutdownAll()
    }

    /// 未建立会话时 ensureCurrentStarted 抛 noSession（appData 分支 fail-closed）。
    @Test func ensureCurrentStartedThrowsWithoutSession() throws {
        let sessionBridge = DialoutSessionBridge(daemonFactory: makeSleepFactory(BridgeCollector()), onBridgeExit: {})
        #expect(throws: DialoutSessionBridgeError.noSession) { try sessionBridge.ensureCurrentStarted() }
    }

    /// 对端离开（relay `peer-left`）主动回收：`recycleCurrent()` 必须回收当前 daemon、清空 `current`，
    /// 且**不**误报 dialout 停机（onBridgeExit）与 daemon 异常死亡（onAbnormalExit）。
    @Test func recycleCurrentRecyclesDaemonClearsCurrentAndDoesNotReportExits() async throws {
        let abnormal = CallbackCounter()
        let bridgeExit = CallbackCounter()
        let collector = BridgeCollector()
        let sessionBridge = DialoutSessionBridge(
            daemonFactory: { onAbnormalExit in
                let b = DaemonBridge(codexPath: "/bin/sleep", arguments: ["300"],
                                     onAbnormalExit: { abnormal.increment() })
                collector.append(b)
                return b
            },
            onBridgeExit: { bridgeExit.increment() })

        try sessionBridge.beginSession()
        let first = collector.bridges[0]
        #expect(first.isRunning)
        #expect(sessionBridge.bridge != nil)
        #expect(sessionBridge.router != nil)

        sessionBridge.recycleCurrent()

        // current 清空：bridge / router 均回 nil（下次 beginSession 直接重 spawn）。
        #expect(sessionBridge.bridge == nil)
        #expect(sessionBridge.router == nil)
        first.waitForTermination()
        #expect(!first.isRunning)              // 精确回收当前 daemon（经 DaemonBridge.terminate()）。

        // terminationHandler / router EOF 均为异步；留窗确认其间无误报。
        try await Task.sleep(for: .milliseconds(300))
        #expect(abnormal.count == 0)           // 主动回收不误报异常死亡。
        #expect(bridgeExit.count == 0)         // dialout 不因回收触发停机。

        // 终态收口无副作用（current 已清空）。
        sessionBridge.shutdownAll()
        sessionBridge.awaitTermination()
    }
}
