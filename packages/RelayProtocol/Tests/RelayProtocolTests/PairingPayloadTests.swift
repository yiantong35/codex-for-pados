import Testing
import Foundation
@testable import RelayProtocol

private let validPublicKey = Data(repeating: 1, count: 32).base64EncodedString()

@Test func pairingURLRoundTrips() throws {
    let p = PairingPayload(relayURL: "wss://ecs.example:9000", sessionId: "sid",
                           devIdentityPubB64: validPublicKey, pairingCode: "PAIR-OK",
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
                           devIdentityPubB64: validPublicKey, pairingCode: "c", expiresAt: 1000)
    #expect(p.isExpired(now: 2000))
    #expect(!p.isExpired(now: 500))
}

@Test(arguments: [
    "codexrelay://pair?relay=https://relay.example&sid=s&pk=\(validPublicKey)&pc=c&exp=1000",
    "codexrelay://pair?relay=wss:///missing-host&sid=s&pk=\(validPublicKey)&pc=c&exp=1000",
    "codexrelay://pair?relay=wss://relay.example&sid=&pk=\(validPublicKey)&pc=c&exp=1000",
    "codexrelay://pair?relay=wss://relay.example&sid=s&pk=not-base64&pc=c&exp=1000",
    "codexrelay://pair?relay=wss://relay.example&sid=s&pk=QQ==&pc=c&exp=1000",
    "codexrelay://pair?relay=wss://relay.example&sid=s&pk=\(validPublicKey)&pc=&exp=1000",
    "codexrelay://pair?relay=wss://relay.example&sid=s&sid=other&pk=\(validPublicKey)&pc=c&exp=1000",
])
func pairingRejectsInvalidSecurityFields(payload: String) {
    #expect(throws: (any Error).self) {
        _ = try PairingPayload(parsing: payload)
    }
}

@Test func pairingRejectsOversizedPayloadAndFields() {
    let oversizedSession = String(repeating: "s", count: PairingPayload.maximumSessionIDBytes + 1)
    let oversizedField = "codexrelay://pair?relay=wss://relay.example&sid=\(oversizedSession)&pk=\(validPublicKey)&pc=c&exp=1000"
    #expect(throws: (any Error).self) { _ = try PairingPayload(parsing: oversizedField) }

    let oversizedPayload = String(repeating: "x", count: PairingPayload.maximumEncodedBytes + 1)
    #expect(throws: (any Error).self) { _ = try PairingPayload(parsing: oversizedPayload) }
}
