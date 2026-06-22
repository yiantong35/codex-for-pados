import XCTest
@testable import DaemonCore

final class SeqBufferTests: XCTestCase {

    private func data(_ s: String) -> Data { Data(s.utf8) }

    // MARK: - seq 分配:单调递增

    func testAppendAllocatesMonotonicallyIncreasingSeqStartingAt1() {
        var buf = SeqBuffer(capacity: 10)

        let a = buf.append(data("a"))
        let b = buf.append(data("b"))
        let c = buf.append(data("c"))

        XCTAssertEqual(a.seq, 1)
        XCTAssertEqual(b.seq, 2)
        XCTAssertEqual(c.seq, 3)
    }

    func testAppendReturnsEventCarryingSameSeqAndPayload() {
        var buf = SeqBuffer(capacity: 10)

        let result = buf.append(data("hello"))

        XCTAssertEqual(result.seq, 1)
        XCTAssertEqual(result.event.seq, 1)
        XCTAssertEqual(result.event.payload, data("hello"))
    }

    // MARK: - 环形淘汰:超容量淘汰最旧

    func testReplayAfterEvictedOldestReturnsNilWhenGapExceedsBuffer() {
        var buf = SeqBuffer(capacity: 3)
        for i in 1...5 { buf.append(data("e\(i)")) } // seq 1..5, 缓冲只剩 3,4,5

        // 客户端 lastSeq=1:下一条应是 seq 2,但 2 已被淘汰(最旧=3)→ 缺口 → 全量 snapshot
        XCTAssertNil(buf.replay(after: 1))
        // 边界:客户端 lastSeq=2,下一条应是 3,3 仍在缓冲 → 无缺口,正常补发 [3,4,5]
        XCTAssertEqual(buf.replay(after: 2)?.map { $0.seq }, [3, 4, 5])
    }

    func testRingKeepsOnlyMostRecentCapacityEvents() {
        var buf = SeqBuffer(capacity: 3)
        for i in 1...5 { buf.append(data("e\(i)")) } // seq 3,4,5 仍在缓冲

        // after=2:其后所有仍在缓冲的事件 = 3,4,5
        let replayed = buf.replay(after: 2)
        XCTAssertEqual(replayed?.map { $0.seq }, [3, 4, 5])
    }

    // MARK: - replay 命中

    func testReplayReturnsOrderedEventsStrictlyAfterGivenSeq() {
        var buf = SeqBuffer(capacity: 10)
        for i in 1...5 { buf.append(data("e\(i)")) }

        let replayed = buf.replay(after: 2)
        XCTAssertEqual(replayed?.map { $0.seq }, [3, 4, 5])
        XCTAssertEqual(replayed?.map { $0.payload }, [data("e3"), data("e4"), data("e5")])
    }

    func testReplayAfterLatestSeqReturnsEmptyArrayNotNil() {
        var buf = SeqBuffer(capacity: 10)
        for i in 1...3 { buf.append(data("e\(i)")) }

        // 客户端已是最新:无缺口,无需补发,返回空数组(区别于 nil 的"需 snapshot")
        let replayed = buf.replay(after: 3)
        XCTAssertEqual(replayed, [])
    }

    func testReplayAfterZeroReturnsAllBufferedEventsWhenNothingEvicted() {
        var buf = SeqBuffer(capacity: 10)
        for i in 1...3 { buf.append(data("e\(i)")) }

        // after=0 且最旧未淘汰(最旧=1, 0 < 1 但无缺口因为 1 仍在)→ 返回全部
        let replayed = buf.replay(after: 0)
        XCTAssertEqual(replayed?.map { $0.seq }, [1, 2, 3])
    }

    // MARK: - 空缓冲边界

    func testReplayOnEmptyBufferReturnsEmptyArray() {
        let buf = SeqBuffer(capacity: 10)

        // 从未 append:没有任何缺口可言,返回空数组(无需 snapshot)
        XCTAssertEqual(buf.replay(after: 0), [])
        XCTAssertEqual(buf.replay(after: 5), [])
    }
}
