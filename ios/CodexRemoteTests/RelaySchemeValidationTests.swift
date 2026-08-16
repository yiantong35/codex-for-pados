import Testing
import Foundation
import RelayProtocol
@testable import CodexRemote

/// P3-wss（组 6）：生产强制 wss 的 scheme 校验断言。
/// - wss 恒放行；生产明文 ws 拒绝；ws 仅 loopback + DEBUG 放行。
struct RelaySchemeValidationTests {

    @Test func wssAlwaysAllowed() throws {
        try RelaySchemeValidator.validate(url: URL(string: "wss://relay.example/ws")!)
    }

    @Test func plainWsNonLoopbackRejected() {
        #expect(throws: RelaySchemeError.insecureScheme) {
            try RelaySchemeValidator.validate(url: URL(string: "ws://relay.example/ws")!)
        }
    }

    @Test func plainWsLoopbackAllowedInDebugOnly() throws {
        let url = URL(string: "ws://127.0.0.1:9000/ws")!
        #if DEBUG
        try RelaySchemeValidator.validate(url: url)          // 开发：loopback 放行
        #else
        #expect(throws: RelaySchemeError.insecureScheme) { try RelaySchemeValidator.validate(url: url) }
        #endif
    }

    /// 6.3：各 scheme 载荷经 ViewModel 的端到端判定矩阵——wss 放行 / 生产明文拒 / 开发 loopback 放行。
    @MainActor
    @Test func importMatrixAcrossSchemes() {
        let publicKey = Data(repeating: 1, count: 32).base64EncodedString()
        func result(_ relay: String, now: Int64 = 0) -> Error? {
            let vm = RelayPairingImportViewModel()
            vm.pasted = PairingPayload(relayURL: relay, sessionId: "s",
                devIdentityPubB64: publicKey, pairingCode: "C", expiresAt: 9_999_999_999).toURLString()
            do { _ = try vm.makeMachineConfig(now: now); return nil } catch { return error }
        }
        #expect(result("wss://relay.example/ws") == nil)                                    // wss 放行
        #expect(result("ws://relay.example/ws") as? PairingImportError == .insecureScheme)   // 生产明文拒
        #if DEBUG
        #expect(result("ws://127.0.0.1:9000/ws") == nil)                                    // 开发 loopback 放行
        #endif
    }
}
