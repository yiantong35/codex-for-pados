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

    @MainActor
    @Test func pendingPairingPeekIsNonDestructiveThenTakeConsumes() {
        let store = PendingPairingStore()
        let id = UUID()
        store.stash("code-abc", for: id)
        #expect(store.peek(for: id) == "code-abc")   // 只读
        #expect(store.peek(for: id) == "code-abc")   // 再读仍在（不删）
        #expect(store.take(for: id) == "code-abc")   // 消费
        #expect(store.peek(for: id) == nil)          // 已删
        #expect(store.take(for: id) == nil)          // 幂等：再 take 为 nil 不崩
    }
}
