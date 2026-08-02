import Testing
import Foundation
@testable import RelayProtocol

@Test func relaySignalRoundTrips() throws {
    let s = RelaySignal(kind: RelaySignal.peerLeftKind, sessionId: "sess-1")
    let decoded = try RelaySignal(decoding: try s.encoded())
    #expect(decoded == s)
    #expect(decoded.kind == "peer-left")
}

// 关键：peer-left 信号与 SecureEnvelope 必须能靠「有无 kind 字段」互相区分（试解歧义）。
@Test func relaySignalDisambiguatesFromSecureEnvelope() throws {
    let sig = try RelaySignal(kind: RelaySignal.peerLeftKind, sessionId: "s").encoded()
    // SecureEnvelope 无 kind 字段 → 不应误解成 RelaySignal
    let env = SecureEnvelope(v: 1, sessionId: "s", keyEpoch: 0, sender: .devMachine,
                             counter: 1, ciphertext: Data([1]), tag: Data([2]))
    let envData = try env.encoded()
    #expect((try? RelaySignal(decoding: envData)) == nil)          // 缺 kind → 解不出 signal
    #expect((try? SecureEnvelope(decoding: sig)) == nil)           // 缺 sender/counter → 解不出 envelope
}
