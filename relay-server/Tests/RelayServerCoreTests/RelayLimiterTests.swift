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

// 房间配额引用计数:同房多连接对称释放。一端离开不得提前释放仍有另一端的房间(fail-closed)，
// 且被拒/额外连接的 releaseRoom 不得把存活房间凭空释放。
@Test func admitRoomRefcountedReleaseKeepsLiveRoom() {
    let l = RelayLimiter(maxPerIP: 100, maxRooms: 1, ratePerMinute: 100)
    #expect(l.admitRoom(sessionId: "s"))   // 第一端建房，占 1 格
    #expect(l.admitRoom(sessionId: "s"))   // 第二端加入同房，仍 true，不占新格
    l.releaseRoom(sessionId: "s")          // 一端离开：房间仍有另一端，不得释放
    #expect(!l.admitRoom(sessionId: "t"))  // 房间总数仍满 → 新房间被拒（证明 "s" 未被提前释放）
    l.releaseRoom(sessionId: "s")          // 另一端也离开：房间真正释放
    #expect(l.admitRoom(sessionId: "t"))   // 现在 "t" 可入
}

// fail-closed 不计费:被拒的 admit 不得递增 per-IP 并发、不得写入速率窗口。
@Test func rejectedAdmitDoesNotConsumeQuota() {
    // per-IP 满时被拒，不应把已满的并发继续抬高——释放一次后应恰好能再进一条。
    let l = RelayLimiter(maxPerIP: 1, maxRooms: 100, ratePerMinute: 100)
    #expect(l.admit(ip: "7.7.7.7", now: 0))
    #expect(!l.admit(ip: "7.7.7.7", now: 0))   // 被拒
    #expect(!l.admit(ip: "7.7.7.7", now: 0))   // 再被拒（前次拒绝未抬高计数）
    l.release(ip: "7.7.7.7")
    #expect(l.admit(ip: "7.7.7.7", now: 0))    // 释放一次即可再进一条（并发计数未被拒绝污染）

    // 速率满时被拒，不应把被拒次数计入窗口——窗口只记真正放行的建连。
    let r = RelayLimiter(maxPerIP: 100, maxRooms: 100, ratePerMinute: 1)
    #expect(r.admit(ip: "8.8.8.8", now: 0))
    #expect(!r.admit(ip: "8.8.8.8", now: 0))   // 速率被拒（不入窗口）
    #expect(r.admit(ip: "8.8.8.8", now: 61))   // 首条滑出后放行（被拒的两次未占窗口）
}

// 4.4：正常一对连接(dev+iPad 同 IP 各一条)远低于配额 → 始终放行，超限不误伤正常流量。
@Test func normalTrafficWithinQuotaAlwaysAdmitted() {
    let l = RelayLimiter(maxPerIP: RelayLimits.maxConnectionsPerIP,
                         maxRooms: RelayLimits.maxRooms, ratePerMinute: RelayLimits.connectRatePerMinute)
    #expect(l.admit(ip: "10.0.0.1", now: 0))
    #expect(l.admit(ip: "10.0.0.1", now: 0))
    #expect(l.admitRoom(sessionId: "sid-normal"))
}
