import Testing
import Foundation
@testable import RelayProtocol

@Test func transcriptIsLengthPrefixedAndOrderSensitive() {
    let a = Transcript.encode([Data("hello".utf8), Data("world".utf8)])
    let b = Transcript.encode([Data("world".utf8), Data("hello".utf8)])
    #expect(a != b)                       // 顺序敏感
    #expect(a.count == 4 + 5 + 4 + 5)     // 每段 4 字节大端长度前缀
}

@Test func transcriptEmptyFields() {
    let t = Transcript.encode([Data(), Data("x".utf8)])
    #expect(t.count == 4 + 0 + 4 + 1)
}
