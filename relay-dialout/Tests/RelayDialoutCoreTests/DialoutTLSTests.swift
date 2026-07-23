import Testing
@testable import RelayDialoutCore

/// 客户端 TLS handler 能用默认客户端配置构造（wss 编译 + 基本可用性）。
@Test func clientTLSHandlerBuildsWithDefaultClientConfig() throws {
    _ = try DialoutTLS.makeClientHandler(serverHostname: "relay.example.com")
}
