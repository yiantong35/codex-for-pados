import Foundation

/// dialout proxy 桥（`ProxyBridge`）的生命周期状态机——从 `main.swift` 的 `DialoutWSHandler`
/// 抽出成可单测单元（#8）。收口两件事：
///  - **#8a 启桥失败冒泡**：`ensureStarted()` 不吞 `bridge.start()` 错，失败**不**置 `isStarted`，
///    由调用方（ws handler）据此关连接（fail-closed），绝不在桥未起时静默继续。
///  - **#8b 精确回收**：`shutdown()` 只 terminate 自己启过的这一个子进程（幂等）。
///    relay 瞬断不会调用它；supervisor 仅在信任、bridge 或用户终态时统一回收。
///
/// ⚠️ 进程安全：只经 `ProxyBridge`（精确 PID）操作，绝不 pkill/宽匹配 kill。
public final class BridgeLifecycle: @unchecked Sendable {
    private let bridge: ProxyBridge
    private let lock = NSLock()
    private var started = false

    public init(bridge: ProxyBridge) {
        self.bridge = bridge
    }

    /// 自己是否已成功启桥（启动失败不置位）。
    public var isStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return started
    }

    /// 幂等启桥：已启则直接返回；未启则 `try bridge.start()`，**抛错冒泡**（不吞），
    /// 只有成功才置 `started`。抛错时 `started` 保持 false，调用方应关连接（fail-closed）。
    public func ensureStarted() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }
        try bridge.start()
        started = true
    }

    /// 精确回收自己启过的子进程（幂等）：从未启桥或已回收则无副作用。
    public func shutdown() {
        lock.lock()
        defer { lock.unlock() }
        guard started else { return }
        started = false
        bridge.terminate()
    }
}
