import Foundation

/// 一条经 daemon 分配序号的事件。
/// Task 1 阶段 payload 用 `Data` 占位透传;Envelope (Task 2) 再精化结构。
public struct Event: Equatable, Sendable {
    public let seq: UInt64
    public let payload: Data

    public init(seq: UInt64, payload: Data) {
        self.seq = seq
        self.payload = payload
    }
}

/// SeqBuffer:单调递增 seq 分配 + 固定容量环形缓冲 + 重连补发查询。
/// 纯逻辑,无 IO。非线程安全(由调用方 actor 隔离,见 Hub / Task 4)。
public struct SeqBuffer {
    /// 缓冲最大保留事件数;超出淘汰最旧。
    public let capacity: Int

    /// 已分配的最后一个 seq(0 表示尚未分配过)。
    private var lastSeq: UInt64 = 0

    /// 环形缓冲,按 seq 升序保存最近 `capacity` 条事件。
    private var ring: [Event] = []

    public init(capacity: Int = 1000) {
        precondition(capacity > 0, "capacity must be positive")
        self.capacity = capacity
        ring.reserveCapacity(capacity)
    }

    /// 分配下一个 seq,封装为 Event 入环形缓冲;超容量淘汰最旧。
    @discardableResult
    public mutating func append(_ payload: Data) -> (seq: UInt64, event: Event) {
        lastSeq += 1
        let event = Event(seq: lastSeq, payload: payload)
        ring.append(event)
        if ring.count > capacity {
            ring.removeFirst(ring.count - capacity)
        }
        return (lastSeq, event)
    }

    /// 返回 seq > `after` 且仍在缓冲内的有序事件。
    ///
    /// - 无缺口(`after` 之后的事件未被淘汰,或缓冲为空)→ 返回有序数组(可能为空)。
    /// - 有缺口(`after` 之后存在已被淘汰的事件)→ 返回 `nil`,表示需全量 snapshot。
    public func replay(after: UInt64) -> [Event]? {
        // 缓冲为空:从未 append 或全被读空。无事件即无缺口。
        guard let oldest = ring.first else {
            return []
        }
        // 客户端缺失的第一条是 after+1。若它早于缓冲最旧,则中间有被淘汰的事件 → 缺口。
        if after + 1 < oldest.seq {
            return nil
        }
        return ring.filter { $0.seq > after }
    }
}
