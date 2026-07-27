import Testing
@testable import RelayServerCore

// RelayLimiter：进程内计数的资源配额（per-IP 并发 + 房间总数 + 建连速率滑窗）。
// 「超大分片不耗内存」由 FrameAccumulatorTests.accumulatorOverflowsBeyondCap 覆盖
// （overflow 时 removeAll，缓冲不无界增长），此处不重复。

@Test func limiterRejectsBeyondPerIP() {
    let l = RelayLimiter(maxPerIP: 2, maxRooms: 100, ratePerMinute: 100)
    #expect(l.admit(ip: "1.1.1.1", now: 0))
    #expect(l.admit(ip: "1.1.1.1", now: 0))
    #expect(!l.admit(ip: "1.1.1.1", now: 0))   // 第 3 条超 per-IP → 拒
    l.release(ip: "1.1.1.1")
    #expect(l.admit(ip: "1.1.1.1", now: 0))     // 释放后可再连
    #expect(l.admit(ip: "2.2.2.2", now: 0))     // 别的 IP 不受影响
}

@Test func limiterRateLimitsPerMinute() {
    let l = RelayLimiter(maxPerIP: 1000, maxRooms: 1000, ratePerMinute: 2)
    #expect(l.admit(ip: "9.9.9.9", now: 0))
    #expect(l.admit(ip: "9.9.9.9", now: 1))
    #expect(!l.admit(ip: "9.9.9.9", now: 2))    // 1 分钟内第 3 次建连 → 限流
    #expect(l.admit(ip: "9.9.9.9", now: 61))    // 窗口滑出后放行
}

@Test func limiterCapsRoomTotal() {
    let l = RelayLimiter(maxPerIP: 100, maxRooms: 1, ratePerMinute: 100)
    #expect(l.admitRoom(sessionId: "a"))
    #expect(!l.admitRoom(sessionId: "b"))       // 房间总数超上限 → 拒
    l.releaseRoom(sessionId: "a")
    #expect(l.admitRoom(sessionId: "b"))
}
