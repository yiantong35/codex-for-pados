import Testing
import NIOSSL
@testable import RelayDialoutCore

/// 客户端 TLS handler 能用默认客户端配置构造（wss 编译 + 基本可用性）。
@Test func clientTLSHandlerBuildsWithDefaultClientConfig() throws {
    _ = try DialoutTLS.makeClientHandler(serverHostname: "relay.example.com")
}

/// 锁死不变量：拨出客户端 TLS 启用完整证书校验（含主机名）。防回归成 .none / .noHostnameVerification（防 MITM 护栏）。
/// `DialoutTLS.makeClientHandler` 走 `NIOSSLContext(configuration: .makeClientConfiguration())`，
/// 后者默认 `certificateVerification == .fullVerification`；此断言固化该默认，防未来被改弱。
@Test func clientTLSUsesFullCertificateVerification() {
    let config = TLSConfiguration.makeClientConfiguration()
    #expect(config.certificateVerification == .fullVerification)
}
