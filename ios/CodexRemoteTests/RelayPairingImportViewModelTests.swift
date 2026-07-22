import XCTest
import RelayProtocol
@testable import CodexRemote

final class RelayPairingImportViewModelTests: XCTestCase {
    func testValidPasteParsesToMachineConfig() throws {
        let vm = RelayPairingImportViewModel()
        vm.pasted = "codexrelay://pair?relay=wss://x&sid=s&pk=QQ&pc=c&exp=9999999999"
        let cfg = try vm.makeMachineConfig(now: 1)
        if case .relay = cfg.connection {} else { XCTFail("expected .relay connection") }
    }

    func testExpiredPayloadRejected() {
        let vm = RelayPairingImportViewModel()
        vm.pasted = "codexrelay://pair?relay=wss://x&sid=s&pk=QQ&pc=c&exp=1000"
        XCTAssertThrowsError(try vm.makeMachineConfig(now: 2000))
    }

    func testGarbageRejectedWithMessage() {
        let vm = RelayPairingImportViewModel()
        vm.pasted = "not a url"
        XCTAssertThrowsError(try vm.makeMachineConfig(now: 1))
    }
}
