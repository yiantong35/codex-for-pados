import Testing
@testable import RelayProtocol

@Test func versionTagStable() {
    #expect(RelayProtocolVersion.tag == "codexrelay-e2ee-v1")
    #expect(RelayProtocolVersion.wire == 1)
}
