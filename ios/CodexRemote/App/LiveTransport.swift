import Foundation
import Crypto

/// 生产 transport 工厂：经 SSH(ed25519) withExec `codex app-server proxy --sock`
/// 接入共享 daemon control socket，通道内做 ws 握手 + 帧编解码（ProxyChannel）。
/// 密钥不进 `ConnectionConfig`，由调用方（CodexRemoteApp 的 transportFactory 闭包）捕获 KeyManager 传入。
@MainActor
func makeSharedDaemonTransport(_ config: ConnectionConfig,
                              key: Curve25519.Signing.PrivateKey) async throws -> MessageTransport {
    let channel = try await SSHClientWrapper.connect(
        host: config.host, sshPort: config.sshPort,
        auth: .ed25519Key(user: config.user, key: key),
        controlSockPath: config.controlSockPath)
    return channel   // ProxyChannel 已在 connect() 内 start()
}

/// 生产工厂闭包（注入 ConnectionStore.transportFactory）：从 KeyManager 取本机私钥后建 SSH+proxy transport。
/// 密钥取法以 KeyManager 实际 API 为准（`privateKey()`）；缺密钥抛 `sshAuthFailed`。
@MainActor
func liveTransportFactory(_ config: ConnectionConfig) async throws -> MessageTransport {
    guard let key = KeyManager().privateKey() else {
        throw TransportError.sshAuthFailed("缺少本机密钥")
    }
    return try await makeSharedDaemonTransport(config, key: key)
}
