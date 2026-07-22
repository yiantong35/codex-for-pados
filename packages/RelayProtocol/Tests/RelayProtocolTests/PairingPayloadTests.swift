import Testing
import Foundation
@testable import RelayProtocol

@Test func pairingURLRoundTrips() throws {
    let p = PairingPayload(relayURL: "wss://ecs.example:9000", sessionId: "sid",
                           devIdentityPubB64: "QUJD", pairingCode: "PAIR-OK",
                           expiresAt: 1_900_000_000)
    let url = p.toURLString()
    #expect(url.hasPrefix("codexrelay://pair?"))
    let back = try PairingPayload(parsing: url)
    #expect(back == p)
}

@Test func pairingRejectsUnknownScheme() {
    #expect(throws: PairingError.badFormat) {
        _ = try PairingPayload(parsing: "https://x?relay=a")
    }
}

@Test func pairingExpiryDetected() throws {
    let p = PairingPayload(relayURL: "wss://x", sessionId: "s",
                           devIdentityPubB64: "QQ", pairingCode: "c", expiresAt: 1000)
    #expect(p.isExpired(now: 2000))
    #expect(!p.isExpired(now: 500))
}
