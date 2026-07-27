import Testing
import Foundation
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
}
