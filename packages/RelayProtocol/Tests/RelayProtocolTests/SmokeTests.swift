import Testing
@testable import RelayProtocol

@Test func versionTagStable() {
    #expect(RelayProtocolVersion.tag == "codexrelay-e2ee-v2")   // F1：proof 扩至完整 ClientHello，bump v1→v2
    #expect(RelayProtocolVersion.wire == 1)
}
