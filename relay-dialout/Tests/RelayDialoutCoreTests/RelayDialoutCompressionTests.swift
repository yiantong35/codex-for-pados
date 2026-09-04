import Testing
import Foundation
@testable import RelayDialoutCore

@Test func compressBenefitForRepeatedData() throws {
    let raw = Data(repeating: 0x41, count: 2 * 1024 * 1024)
    guard let packed = RelayDialoutCompression.compress(raw) else {
        Issue.record("compress should succeed on repeated data")
        return
    }
    #expect(packed.count < raw.count)
    let back = try RelayDialoutCompression.decompress(packed, maxBytes: 4 * 1024 * 1024)
    #expect(back == raw)
}

@Test func incompressibleDataReturnsNilOrNotBeneficial() throws {
    // 随机高熵数据不可压缩 → compress 返回 nil 或压缩字节不小于原字节（无收益）。
    let raw = Data((0..<256 * 1024).map { _ in UInt8.random(in: 0...255) })
    let packed = RelayDialoutCompression.compress(raw)
    if let packed { #expect(packed.count >= raw.count) }   // 不可压缩：无收益
}
