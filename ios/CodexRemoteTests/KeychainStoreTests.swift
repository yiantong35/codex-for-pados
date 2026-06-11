import XCTest
@testable import CodexRemote

final class KeychainStoreTests: XCTestCase {
    func testSaveLoadDelete() throws {
        let store = KeychainStore(service: "com.codexremote.test")
        // 清理可能的残留，保证测试可重复运行。
        try? store.delete("ssh-credential")

        try store.save("secret-key", for: "ssh-credential")
        XCTAssertEqual(try store.load("ssh-credential"), "secret-key")
        try store.delete("ssh-credential")
        XCTAssertNil(try store.load("ssh-credential"))
    }
}
