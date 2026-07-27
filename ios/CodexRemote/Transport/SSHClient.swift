import Foundation
import Citadel
import NIOCore
import NIOSSH
import Crypto

/// host key 决策纯逻辑（从 NIO 回调抽出便于单测）：序列化后的 host key 字节交 store 做 TOFU 校验。
/// 首次信任持久化、再连比对、变更抛 `SSHHostKeyError.hostKeyChanged`（fail-closed）。
enum SSHHostKeyDecision {
    static func decide(store: SSHHostKeyStoring, machineKey: String, hostKeyBytes: Data) throws {
        try store.verifyOrTrust(machineKey: machineKey, presentedHostKey: hostKeyBytes)
    }
}

/// TOFU host key 校验 delegate：首信持久化、再连比对、变更 fail-closed 拒连（fail promise）。
/// 绝不无条件放行（替代旧的无条件接受配置）。序列化用 `NIOSSHPublicKey.write(to:)` 的
/// SSH host key 原始字节（含算法前缀，稳定可比），存 Keychain 并逐字节比对。
final class TOFUHostKeyDelegate: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let store: SSHHostKeyStoring
    private let machineKey: String
    init(store: SSHHostKeyStoring, machineKey: String) {
        self.store = store
        self.machineKey = machineKey
    }
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        var buf = ByteBufferAllocator().buffer(capacity: 128)
        hostKey.write(to: &buf)
        let bytes = Data(buf.readableBytesView)
        do {
            try SSHHostKeyDecision.decide(store: store, machineKey: machineKey, hostKeyBytes: bytes)
            validationCompletePromise.succeed(())   // 首信/匹配 → 接受
        } catch {
            validationCompletePromise.fail(error)   // 变更/首信持久化失败 → 拒连（不进 initialize）
        }
    }
}

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
                        controlSockPath: String,
                        hostKeyStore: SSHHostKeyStoring = KeychainSSHHostKeyStore(),
                        machineKey: String) async throws -> ProxyChannel {
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
        // TOFU host key 校验：首次信任并持久化、再连比对、变更 fail-closed 拒连报警。
        // machineKey 为该 SSH 连接的稳定标识（user@host:port），独立于 relay E2E TOFU。
        let hostKeyDelegate = TOFUHostKeyDelegate(store: hostKeyStore, machineKey: machineKey)
        do {
            connected = try await Citadel.SSHClient.connect(
                host: host,
                port: sshPort,
                authenticationMethod: method,
                hostKeyValidator: .custom(hostKeyDelegate),   // TOFU + fail-closed（替换旧无条件放行）
                reconnect: .never
            )
        } catch {
            // host key 变更/首信持久化失败与鉴权失败都落此；区分错误类型给明确报警文案。
            if let e = error as? SSHHostKeyError {
                throw TransportError.sshAuthFailed("SSH host key 校验失败（可能中间人或服务器身份变更）：\(e)")
            }
            throw TransportError.sshAuthFailed("\(error)")
        }

        // 把 client 独占交给 ProxyChannel。此处 connected 处于 nonisolated 的 disconnected
        // region，传入 actor init 不构成跨边界竞争。
        // 接共享 daemon control sock（路径来自配置 T2.4，不硬编码）。
        // 注：受信内网、路径为已知固定值，暂不做 shell 转义；如未来路径含特殊字符再加引用。
        // 缺口①：连接前经官方幂等命令确保 app-server 就绪，并以其返回 socketPath 作 proxy 入参
        //（替代硬拼 controlSockPath，天然适配非默认 CODEX_HOME/用户目录）。
        let sockPath: String
        do {
            let startOut = try await connected.executeCommand(DaemonBootstrap.startCommand)
            let text = startOut.getString(at: startOut.readerIndex, length: startOut.readableBytes) ?? ""
            sockPath = try DaemonBootstrap.parse(text).socketPath
        } catch let e as TransportError {
            throw e
        } catch {
            throw TransportError.proxyFailed("daemon start 失败：\(error)")
        }

        let command = DaemonBootstrap.proxyCommand(sockPath: sockPath)
        let channel = ProxyChannel(client: connected, command: command)
        await channel.start()
        return channel
    }
}
