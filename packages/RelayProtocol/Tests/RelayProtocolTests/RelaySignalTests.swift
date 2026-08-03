import Testing
import Foundation
@testable import RelayProtocol

@Test func relaySignalRoundTrips() throws {
    let s = RelaySignal(kind: RelaySignal.peerLeftKind, sessionId: "sess-1")
    let decoded = try RelaySignal(decoding: try s.encoded())
    #expect(decoded == s)
    #expect(decoded.kind == "peer-left")
}

// 关键：peer-left 信号与 SecureEnvelope 必须能靠帧形状互相区分（试解歧义）。
// RelaySignal.kind 是 String；SecureEnvelope 是加密信封（含 sender/counter/ciphertext/tag，
// 且其 kind 为数值型 RelayFrameKind）。互相试解必失败 → 构造性证明零知识不破坏。
@Test func relaySignalDisambiguatesFromSecureEnvelope() throws {
    let sig = try RelaySignal(kind: RelaySignal.peerLeftKind, sessionId: "s").encoded()
    let env = SecureEnvelope(v: 1, sessionId: "s", keyEpoch: 0, sender: .devMachine,
                             counter: 1, kind: .appData, ciphertext: Data([1]), tag: Data([2]))
    let envData = try env.encoded()
    #expect((try? RelaySignal(decoding: envData)) == nil)   // envelope 形状 → 解不出 signal
    #expect((try? SecureEnvelope(decoding: sig)) == nil)    // signal 形状 → 解不出 envelope
}

// tag 未变断言：本任务不碰版本，确认当前值即可（防止无意 bump）。
@Test func relayProtocolVersionTagUnchanged() {
    #expect(RelayProtocolVersion.tag == "codexrelay-e2ee-v2")
}
