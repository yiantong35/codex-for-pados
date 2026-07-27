import Testing
import Foundation
@testable import CodexRemote

struct PendingPairingStoreTests {

    @MainActor
    @Test func pendingPairingStashAndTakeOnce() {
        let store = PendingPairingStore()
        let id = UUID()
        store.stash("code-xyz", for: id)
        #expect(store.take(for: id) == "code-xyz")   // 取出
        #expect(store.take(for: id) == nil)          // 一次性：再取为 nil（不长驻）
    }
}
