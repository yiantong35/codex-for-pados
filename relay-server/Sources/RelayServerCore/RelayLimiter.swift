import Foundation

/// relay 面向公网的资源配额（决策 D3：纯加法防御，进程内内存计数——relay 单进程）。
///
/// 三道闸:
/// - **建连速率**:每 IP 每分钟建连次数(滑窗时间戳)。
/// - **per-IP 并发**:每 IP 同时在线连接数。
/// - **房间总数**:活跃 sessionId 数上限。
///
/// fail-closed:任一超限即拒。线程安全用 NSLock(NIO 多连接并发准入/释放)。
public final class RelayLimiter: @unchecked Sendable {
    private let maxPerIP: Int
    private let maxRooms: Int
    private let ratePerMinute: Int
    private let lock = NSLock()
    private var perIP: [String: Int] = [:]
    private var recentConnects: [String: [TimeInterval]] = [:]
    private var activeRooms: Set<String> = []

    public init(maxPerIP: Int, maxRooms: Int, ratePerMinute: Int) {
        self.maxPerIP = maxPerIP
        self.maxRooms = maxRooms
        self.ratePerMinute = ratePerMinute
    }

    /// 准入判定:先滑窗限流,再 per-IP 并发。通过即计数(连接建立)。
    /// 被拒时**不计入**速率窗口与并发数(拒绝的连接不占配额)。
    public func admit(ip: String, now: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var stamps = (recentConnects[ip] ?? []).filter { now - $0 < 60 }
        if stamps.count >= ratePerMinute { recentConnects[ip] = stamps; return false }
        if (perIP[ip] ?? 0) >= maxPerIP { recentConnects[ip] = stamps; return false }
        stamps.append(now); recentConnects[ip] = stamps
        perIP[ip, default: 0] += 1
        return true
    }

    /// 连接关闭时递减 per-IP 并发计数。
    public func release(ip: String) {
        lock.lock(); defer { lock.unlock() }
        if let c = perIP[ip] { perIP[ip] = c > 1 ? c - 1 : nil }
    }

    /// 房间准入:已存在的房间(第二端加入)不算新增;否则受房间总数上限约束。
    public func admitRoom(sessionId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if activeRooms.contains(sessionId) { return true }   // 已存在房间的第二端不算新增
        if activeRooms.count >= maxRooms { return false }
        activeRooms.insert(sessionId)
        return true
    }

    /// 房间回收(两端皆离开时)。
    public func releaseRoom(sessionId: String) {
        lock.lock(); defer { lock.unlock() }
        activeRooms.remove(sessionId)
    }
}
