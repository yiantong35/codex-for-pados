import Testing
@testable import RelayServerCore

// RelayLimiter：进程内计数的资源配额（全局并发 + 房间总数）。
// per-IP 限流交可信反代（Caddy）承担（D2）；relay 只保全局并发 + 房间总数两道闸。
// 「超大分片不耗内存」由 FrameAccumulatorTests.accumulatorOverflowsBeyondCap 覆盖
// （overflow 时 removeAll，缓冲不无界增长），此处不重复。

// 全局并发：到顶即拒；释放后可再 admit；双释钳 0 不穿透。
@Test func limiterCapsGlobalConcurrency() {
    let l = RelayLimiter(maxTotalConnections: 2, maxRooms: 100)
    #expect(l.admitConnection())
    #expect(l.admitConnection())
    #expect(!l.admitConnection())        // 第 3 条超全局并发 → 拒
    l.releaseConnection()
    #expect(l.admitConnection())         // 释放后可再 admit
}

// 双释不得把计数压到 0 以下（防 fail-open：负数会让后续无限放行）。
@Test func releaseClampsAtZero() {
    let l = RelayLimiter(maxTotalConnections: 1, maxRooms: 100)
    l.releaseConnection(); l.releaseConnection()   // 空释两次
    #expect(l.admitConnection())                   // 仍只允许 1 条
    #expect(!l.admitConnection())
}

// 反代场景：所有连接同源（无 IP 概念）→ 只受全局并发约束，正常多用户互不误伤。
@Test func reverseProxyManyConnectionsShareNoPerIPBucket() {
    let l = RelayLimiter(maxTotalConnections: RelayLimits.maxTotalConnections, maxRooms: RelayLimits.maxRooms)
    for _ in 0..<50 { #expect(l.admitConnection()) }   // 远低于全局上限 → 全放行，不塌单桶
}

// 房间配额引用计数不回归。
@Test func limiterCapsRoomTotal() {
    let l = RelayLimiter(maxTotalConnections: 100, maxRooms: 1)
    #expect(l.admitRoom(sessionId: "a"))
    #expect(!l.admitRoom(sessionId: "b"))       // 房间总数超上限 → 拒
    l.releaseRoom(sessionId: "a")
    #expect(l.admitRoom(sessionId: "b"))
}

// 房间配额引用计数:同房多连接对称释放。一端离开不得提前释放仍有另一端的房间(fail-closed)，
// 且被拒/额外连接的 releaseRoom 不得把存活房间凭空释放。
@Test func admitRoomRefcountedReleaseKeepsLiveRoom() {
    let l = RelayLimiter(maxTotalConnections: 100, maxRooms: 1)
    #expect(l.admitRoom(sessionId: "s"))   // 第一端建房，占 1 格
    #expect(l.admitRoom(sessionId: "s"))   // 第二端加入同房，仍 true，不占新格
    l.releaseRoom(sessionId: "s")          // 一端离开：房间仍有另一端，不得释放
    #expect(!l.admitRoom(sessionId: "t"))  // 房间总数仍满 → 新房间被拒（证明 "s" 未被提前释放）
    l.releaseRoom(sessionId: "s")          // 另一端也离开：房间真正释放
    #expect(l.admitRoom(sessionId: "t"))   // 现在 "t" 可入
}
