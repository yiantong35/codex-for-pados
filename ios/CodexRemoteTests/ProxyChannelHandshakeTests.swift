import XCTest
@testable import CodexRemote

final class ProxyChannelHandshakeTests: XCTestCase {
    func testAwaitReturnsWhenAlreadyDone() async throws {
        let ch = ProxyChannel.makeForTesting()
        await ch.markHandshakeDoneForTesting()
        try await ch.awaitHandshake()
    }
    func testAwaitResumesOnLaterDone() async throws {
        let ch = ProxyChannel.makeForTesting()
        let waiter = Task { try await ch.awaitHandshake() }
        try await Task.sleep(nanoseconds: 20_000_000)
        await ch.markHandshakeDoneForTesting()
        try await waiter.value
    }
    func testAwaitThrowsOnFailure() async throws {
        let ch = ProxyChannel.makeForTesting()
        await ch.markHandshakeFailedForTesting(TransportError.handshakeFailed("boom"))
        do {
            try await ch.awaitHandshake()
            XCTFail("应抛出 handshakeFailed")
        } catch let TransportError.handshakeFailed(msg) {
            XCTAssertEqual(msg, "boom")
        }
    }
}
