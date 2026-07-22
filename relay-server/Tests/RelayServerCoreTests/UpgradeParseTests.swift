import Testing
import RelayProtocol
@testable import RelayServerCore

@Test func parsesValidIPadUpgrade() {
    let r = UpgradeRequest.parseUpgrade(uri: "/relay/abc123", role: "iPad")
    #expect(r?.sessionId == "abc123")
    #expect(r?.role == .iPad)
}

@Test func parsesValidDevMachineUpgrade() {
    let r = UpgradeRequest.parseUpgrade(uri: "/relay/abc123", role: "devMachine")
    #expect(r?.role == .devMachine)
}

@Test func stripsQueryFromPath() {
    let r = UpgradeRequest.parseUpgrade(uri: "/relay/abc?foo=bar", role: "iPad")
    #expect(r?.sessionId == "abc")
}

@Test func rejectsWrongSegmentCount() {
    #expect(UpgradeRequest.parseUpgrade(uri: "/relay", role: "iPad") == nil)
    #expect(UpgradeRequest.parseUpgrade(uri: "/relay/a/b", role: "iPad") == nil)
}

@Test func rejectsEmptySessionId() {
    #expect(UpgradeRequest.parseUpgrade(uri: "/relay/", role: "iPad") == nil)
}

@Test func rejectsNilRole() {
    #expect(UpgradeRequest.parseUpgrade(uri: "/relay/abc", role: nil) == nil)
}

@Test func rejectsIllegalRole() {
    #expect(UpgradeRequest.parseUpgrade(uri: "/relay/abc", role: "hacker") == nil)
}
