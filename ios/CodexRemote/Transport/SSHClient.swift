import Foundation
import Citadel
import NIOCore
import Crypto

/// SSH 鉴权方式。
enum SSHAuth {
    case password(user: String, password: String)
    /// OpenSSH 格式 RSA 私钥（PEM 文本）。passphrase 可选。
    case privateKey(user: String, pem: String, passphrase: String?)
    /// OpenSSH 格式 ed25519 私钥（PEM 文本，`-----BEGIN OPENSSH PRIVATE KEY-----`）。passphrase 可选。
    /// 兼容旧路径，UI 不再使用（已被 app 内生成密钥替代）。
    case ed25519(user: String, pem: String, passphrase: String?)
    /// app 内生成并复用的 ed25519 私钥（CryptoKit 直传，无需 PEM）。
    case ed25519Key(user: String, key: Curve25519.Signing.PrivateKey)
}

/// 封装 spike（Task 3）已验证的 Citadel SSH 建连。
///
/// 设计取舍（依据 spike 注释中的 withExec 长驻闭包约束 + Swift 6 严格并发）：
/// `Citadel.SSHClient` 是非 Sendable 的 final class，其 exec stdin/stdout 句柄
/// （TTYStdinWriter/TTYOutput）只在 `withExec` 的 perform 闭包作用域内有效，闭包退出即关通道。
/// 为避免非 Sendable client 跨 actor 边界引发数据竞争，本类型用一个 **nonisolated static**
/// 工厂建连：在该 nonisolated 上下文里创建的 client 是「disconnected region」，可安全交给
/// `ProxyChannel`（actor）独占持有。ProxyChannel 在其内部启动长驻 withExec 闭包跑
/// `codex app-server --listen stdio://`（read loop + write loop 都在闭包内），outbound 写句柄永不跨 actor。
enum SSHClientWrapper {
    /// 建立 SSH 连接并准备好 `codex app-server --listen stdio://` exec 通道，返回换行分隔 JSON 帧的双向传输。
    ///
    /// - 鉴权失败 → `TransportError.sshAuthFailed`
    /// - 连接建立但 app-server exec 无法启动 → `TransportError.appServerUnreachable`（在 ProxyChannel 内体现为通道关闭）
    static func connect(host: String, sshPort: Int, auth: SSHAuth,
                        controlSockPath: String) async throws -> ProxyChannel {
        let method: SSHAuthenticationMethod
        switch auth {
        case .password(let u, let p):
            method = .passwordBased(username: u, password: p)
        case .privateKey(let u, let pem, let pass):
            let key = try Insecure.RSA.PrivateKey(
                sshRsa: pem,
                decryptionKey: pass?.data(using: .utf8)
            )
            method = .rsa(username: u, privateKey: key)
        case .ed25519(let u, let pem, let pass):
            let key = try Curve25519.Signing.PrivateKey(
                sshEd25519: pem,
                decryptionKey: pass?.data(using: .utf8)
            )
            method = .ed25519(username: u, privateKey: key)
        case .ed25519Key(let u, let key):
            // CryptoKit 私钥直传 Citadel，无需 PEM 解析。
            method = .ed25519(username: u, privateKey: key)
        }

        let connected: Citadel.SSHClient
        do {
            connected = try await Citadel.SSHClient.connect(
                host: host,
                port: sshPort,
                authenticationMethod: method,
                hostKeyValidator: .acceptAnything(),   // TODO Task 11：固定/记录 host key
                reconnect: .never
            )
        } catch {
            throw TransportError.sshAuthFailed("\(error)")
        }

        // 把 client 独占交给 ProxyChannel。此处 connected 处于 nonisolated 的 disconnected
        // region，传入 actor init 不构成跨边界竞争。
        // 接共享 daemon control sock（路径来自配置 T2.4，不硬编码）。
        // 注：受信内网、路径为已知固定值，暂不做 shell 转义；如未来路径含特殊字符再加引用。
        let command = "codex app-server proxy --sock \(controlSockPath)"
        let channel = ProxyChannel(client: connected, command: command)
        await channel.start()
        return channel
    }
}
