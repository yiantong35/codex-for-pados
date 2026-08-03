import Testing
import Foundation
@testable import RelayProtocol

@Test func envelopeRoundTripsThroughJSON() throws {
    let env = SecureEnvelope(
        v: 1, sessionId: "sid-1", keyEpoch: 0,
        sender: .iPad, counter: 42, kind: .appData,
        ciphertext: Data([0xAA, 0xBB]), tag: Data([0xCC]))
    let data = try env.encoded()
    let back = try SecureEnvelope(decoding: data)
    #expect(back == env)
}

@Test func envelopeRejectsMalformed() {
    #expect(throws: (any Error).self) {
        _ = try SecureEnvelope(decoding: Data("not json".utf8))
    }
}
