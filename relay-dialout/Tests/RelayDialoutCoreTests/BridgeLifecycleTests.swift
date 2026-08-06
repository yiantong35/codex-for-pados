import XCTest
import Foundation
@testable import RelayDialoutCore

/// 缺陷 #8：dialout 子进程（proxy 桥）生命周期收口的可单测单元。
/// 旧 `main.swift.ensureBridgeStarted` 吞 `bridge.start()` 错（`:222`）→ iPad 收 SecureReady
/// 后只能干等 initialize 超时；且无 `channelInactive` 处理 → TCP reset（无 connectionClose 帧）
/// 遗留 proxy 子进程。BridgeLifecycle 把「幂等启桥+启动失败冒泡+精确回收」抽出成可测单元。
final class BridgeLifecycleTests: XCTestCase {

    private func makeSock() -> String {
        "/tmp/relay-t5-lifecycle-\(ProcessInfo.processInfo.globallyUniqueString).sock"
    }

    /// #8a：启桥失败必须冒泡（不吞错）。不存在的可执行路径触发 `process.run()` 抛错。
    func testEnsureStartedBubblesStartFailure() {
        let bridge = ProxyBridge(codexPath: "/nonexistent/relay-proxy-stub", sockPath: makeSock())
        let lifecycle = BridgeLifecycle(bridge: bridge)
        XCTAssertThrowsError(try lifecycle.ensureStarted())
        XCTAssertFalse(lifecycle.isStarted) // 启动失败不置 started：连接路径可据此关连接（fail-closed），不静默继续
    }

    /// 幂等：成功启桥只 spawn 一次，第二次 ensureStarted 复用同一 PID（不重复 spawn proxy）。
    func testEnsureStartedIsIdempotent() throws {
        let bridge = ProxyBridge(codexPath: "/bin/sleep", arguments: ["300"], sockPath: makeSock())
        let lifecycle = BridgeLifecycle(bridge: bridge)
        try lifecycle.ensureStarted()
        let pid = bridge.pid
        try lifecycle.ensureStarted()   // 第二次不再 spawn
        XCTAssertEqual(bridge.pid, pid)
        XCTAssertTrue(lifecycle.isStarted)
        lifecycle.shutdown()
    }

    /// #8b：shutdown 回收自己启过的子进程（inactive/reset 退出路径调用），只动自己的 PID，幂等。
    func testShutdownTerminatesStartedBridge() throws {
        let bridge = ProxyBridge(codexPath: "/bin/sleep", arguments: ["300"], sockPath: makeSock())
        let lifecycle = BridgeLifecycle(bridge: bridge)
        try lifecycle.ensureStarted()
        XCTAssertTrue(bridge.isRunning)
        lifecycle.shutdown()
        XCTAssertFalse(bridge.isRunning) // 精确回收自己这一个（非 pkill）
        XCTAssertFalse(lifecycle.isStarted)
        lifecycle.shutdown()            // 幂等：再调不炸
    }

    /// 从未启桥就 reset 的路径：shutdown 安全无副作用（不 terminate、不崩）。
    func testShutdownWithoutStartIsNoOp() {
        let bridge = ProxyBridge(codexPath: "/bin/sleep", arguments: ["300"], sockPath: makeSock())
        let lifecycle = BridgeLifecycle(bridge: bridge)
        lifecycle.shutdown()
        XCTAssertFalse(lifecycle.isStarted)
        XCTAssertFalse(bridge.isRunning)
    }
}
