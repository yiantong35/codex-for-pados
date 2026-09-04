import Foundation

/// 持有并管理「当前 iPad 会话对应的 app-server daemon 桥」三元组（DaemonBridge + BridgeLifecycle + BridgeOutputRouter）。
///
/// 语义（本缺陷的根因修复）：**一次握手成功 = 一个新 iPad 会话 = 一个全新 app-server daemon**。
/// 旧实现把 `DaemonBridge` 在 `main.swift` 顶层只创建一次、由 `BridgeLifecycle.ensureStarted()` 幂等持有，
/// 导致 app-server daemon 启动后再也不死。iPad app 被强杀（如 XCUITest teardown 或用户杀掉）重启后重连，
/// 重握手成功、重新 `initialize` 时会命中**同一个已初始化 daemon**，拿到 `-32600 Already initialized`
/// —— 这正是「app 强杀后无法重连、需重启 relay-dialout」的根因。
///
/// 本类型把「重握手成功时回收旧 daemon 并重生成」协调成可单测单元：
/// `beginSession()` 每次调用都精确回收旧的 `(router, lifecycle)`，并全新 spawn 一个 app-server daemon，
/// 使重连后的 `initialize` 落到全新会话上。`DaemonBridge` 是一次性对象（start→terminate 各至多一次），
/// 故每次会话都新建实例，绝不复用旧 `DaemonBridge`。
public final class DialoutSessionBridge: @unchecked Sendable {
    public typealias DaemonFactory = @Sendable (@escaping @Sendable () -> Void) -> DaemonBridge

    private let daemonFactory: DaemonFactory
    private let onBridgeExit: @Sendable () -> Void
    private let lock = NSLock()
    private var current: (bridge: DaemonBridge, lifecycle: BridgeLifecycle, router: BridgeOutputRouter)?
    private var terminatingBridge: DaemonBridge?

    public init(daemonFactory: @escaping DaemonFactory,
                onBridgeExit: @escaping @Sendable () -> Void) {
        self.daemonFactory = daemonFactory
        self.onBridgeExit = onBridgeExit
    }

    /// 当前会话的 router（用于 attach proxy 输出）；会话未建立时为 nil。
    public var router: BridgeOutputRouter? {
        lock.lock(); defer { lock.unlock() }
        return current?.router
    }

    /// 当前会话的 bridge（用于向 daemon 写回 / rejectUpstream）；会话未建立时为 nil。
    public var bridge: DaemonBridge? {
        lock.lock(); defer { lock.unlock() }
        return current?.bridge
    }

    /// 每次握手完成调用：回收旧会话（若有）并重建一个全新 app-server daemon 会话。
    ///
    /// - 顺序安全：先建新三元组 → 回收旧 router（stop 置 stopping，防止其 streamFinished 误报 bridgeExit）
    ///   → 回收旧 lifecycle（shutdown 置 expectedTermination，防误报 abnormalExit；terminate 在旧 daemon 的
    ///   processQueue 异步 reap，不阻塞 NIO event loop）→ `ensureStarted()` spawn 全新 daemon。
    /// - 启动失败冒泡（不吞）、且**不发布**失败会话——调用方（ws handler）据此关连接（fail-closed），
    ///   绝不静默继续。
    public func beginSession() throws {
        let bridge = daemonFactory(onBridgeExit)
        let lifecycle = BridgeLifecycle(bridge: bridge)
        let router = BridgeOutputRouter(stream: { bridge.incoming }, onBridgeExit: onBridgeExit)

        lock.lock()
        let previous = current
        lock.unlock()

        if let previous {
            previous.router.stop()
            previous.lifecycle.shutdown()
        }

        try lifecycle.ensureStarted()

        lock.lock()
        current = (bridge, lifecycle, router)
        lock.unlock()
    }

    /// 防御性复核：当前会话 daemon 是否已就绪。逻辑上 `beginSession()` 已在握手完成时启动，
    /// 此处仅兜底（appData 分支的旧 `ensureBridgeStarted` 语义）；未建立会话/未启动则抛错，调用方 fail-closed。
    public func ensureCurrentStarted() throws {
        let lifecycle: BridgeLifecycle?
        lock.lock(); lifecycle = current?.lifecycle; lock.unlock()
        guard let lifecycle else { throw DialoutSessionBridgeError.noSession }
        try lifecycle.ensureStarted()
    }

    /// supervisor 终态收口第一步（必须在 stop 事件循环**前**调用）：精确回收当前 daemon 并暂停 router。
    /// - `router.stop()` 取消其 stream task——若留到事件循环停止后，一条 proxy 行被路由时仍会向已停止的
    ///   事件循环 `eventLoop.execute` 而崩溃，故必须在此先停。
    /// - `lifecycle.shutdown()` 仅精确 terminate daemon（非阻塞，实际 reap 在 bridge 的 processQueue 上）。
    /// 幂等；循环内多个重握手产生的旧 daemon 已各自在其 processQueue 上异步 reap，无需在此跟踪。
    public func shutdownAll() {
        let currentSnapshot: (bridge: DaemonBridge, lifecycle: BridgeLifecycle, router: BridgeOutputRouter)?
        lock.lock()
        currentSnapshot = current
        current = nil
        lock.unlock()
        guard let currentSnapshot else { return }
        currentSnapshot.router.stop()
        currentSnapshot.lifecycle.shutdown()
        lock.lock()
        terminatingBridge = currentSnapshot.bridge
        lock.unlock()
    }

    /// supervisor 终态收口第二步（在事件循环停止后调用）：等待当前 daemon 完成精确 TERM/KILL 与 reap。
    public func awaitTermination() {
        let bridge: DaemonBridge?
        lock.lock()
        bridge = terminatingBridge
        terminatingBridge = nil
        lock.unlock()
        bridge?.waitForTermination()
    }
}

public enum DialoutSessionBridgeError: Error, Equatable {
    case noSession
}
