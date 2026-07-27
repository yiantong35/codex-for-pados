import Testing
@testable import RelayServerCore

// FrameAccumulator：分片文本帧累积器。累积到 fin 才产出整消息；
// 超单消息上限即 overflow（调用方须关连接，内存不无界增长）。

@Test func accumulatorCompletesOnFin() {
    var acc = FrameAccumulator(maxBytes: 100)
    #expect(acc.append(Array("ab".utf8), fin: false) == .accumulating)
    #expect(acc.append(Array("cd".utf8), fin: true) == .complete("abcd"))
}

@Test func accumulatorOverflowsBeyondCap() {
    var acc = FrameAccumulator(maxBytes: 3)
    #expect(acc.append(Array("ab".utf8), fin: false) == .accumulating)
    #expect(acc.append(Array("cd".utf8), fin: false) == .overflow)   // 累积超上限 → overflow
}

@Test func accumulatorResetsAfterComplete() {
    var acc = FrameAccumulator(maxBytes: 10)
    _ = acc.append(Array("hi".utf8), fin: true)
    #expect(acc.append(Array("yo".utf8), fin: true) == .complete("yo"))   // 完成后重置，不串消息
}
