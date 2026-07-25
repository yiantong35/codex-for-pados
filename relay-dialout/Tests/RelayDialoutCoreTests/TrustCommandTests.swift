import Testing
@testable import RelayDialoutCore

@Test func parseForgetCommand() {
    #expect(parseTrustCommand(["--forget", "iPad-A"]) == .forget(labelOrPubPrefix: "iPad-A"))
}
@Test func parseForgetAll() {
    #expect(parseTrustCommand(["--forget-all"]) == .forgetAll)
}
@Test func parseListTrusted() {
    #expect(parseTrustCommand(["--list-trusted"]) == .list)
}
@Test func parseEmptyRunsDialout() {
    #expect(parseTrustCommand([]) == .runDialout)
}
@Test func parseForgetWithoutArgIsInvalid() {
    // --forget 缺参数 → 明确的 invalid，而非静默 runDialout
    #expect(parseTrustCommand(["--forget"]) == .invalid("--forget 需要一个 label 或公钥前缀参数"))
}
