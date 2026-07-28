import Foundation

/// relay 面向公网的资源配额（进程内内存计数——relay 单进程）。
/// per-IP 限流由可信反代（Caddy）承担（D2）；relay 只保全局并发 + 房间总数两道闸。fail-closed。
///
/// 两道闸:
/// - **全局并发**:进程内同时在线连接总数上限（`maxTotalConnections`）。
/// - **房间总数**:活跃 sessionId 数上限（`maxRooms`，引用计数）。
///
/// 线程安全用 NSLock(NIO 多连接并发准入/释放)。
public final class RelayLimiter: @unchecked Sendable {
    private let maxTotalConnections: Int
    private let maxRooms: Int
    private let lock = NSLock()
    private var activeConnections = 0
    // 房间引用计数:key=sessionId,value=该房间当前活跃连接数。
    // 用引用计数而非 Set——`admitRoom`/`releaseRoom` 每连接对称加减,房间仅在最后一端离开
    // (计数归零)才真正释放。避免「被拒/额外连接的 releaseRoom 把仍存活的房间凭空释放」
    // 导致房间总数上限 fail-open,也避免正常一对连接中先离开一方提前释放误伤对端重连。
    private var roomRefcount: [String: Int] = [:]

    public init(maxTotalConnections: Int, maxRooms: Int) {
        self.maxTotalConnections = maxTotalConnections
        self.maxRooms = maxRooms
    }

    /// 全局并发准入：未达上限则自增返回 true，否则 false（不计数）。
    public func admitConnection() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard activeConnections < maxTotalConnections else { return false }
        activeConnections += 1
        return true
    }

    /// 连接关闭释放：自减，下限钳制在 0（防双释穿透成负数 → fail-open）。
    public func releaseConnection() {
        lock.lock(); defer { lock.unlock() }
        if activeConnections > 0 { activeConnections -= 1 }
    }

    /// 房间准入:已存在的房间(后续连接加入)不占新配额,只增引用计数;
    /// 新房间受房间总数上限(distinct sessionId 数)约束。
    public func admitRoom(sessionId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let c = roomRefcount[sessionId] {   // 已存在房间的后续连接:加引用,不受总数约束
            roomRefcount[sessionId] = c + 1
            return true
        }
        if roomRefcount.count >= maxRooms { return false }   // 新房间超总数上限 → 拒
        roomRefcount[sessionId] = 1
        return true
    }

    /// 房间回收:减引用,计数归零(最后一端离开)才真正释放房间。
    public func releaseRoom(sessionId: String) {
        lock.lock(); defer { lock.unlock() }
        guard let c = roomRefcount[sessionId] else { return }
        if c > 1 { roomRefcount[sessionId] = c - 1 } else { roomRefcount[sessionId] = nil }
    }
}
