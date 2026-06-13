import XCTest
@testable import CodexRemote

/// 模拟器上验证 Citadel withExec 真实运行的集成测试（spike 补充）。
///
/// 这是一个**真连 SSH** 的集成测试：经 `SSHClientWrapper.connect`（内部 Citadel
/// `withExec`）在远端起 `codex app-server --listen stdio://`，发 `initialize`
/// 握手并断言首条响应含 `userAgent` / `codexHome`。
///
/// ## 不碰任何密钥：全部连接参数从环境变量读
/// - `CODEX_SPIKE_HOST`：SSH 主机（缺失/空 → 整个测试 `XCTSkip` 跳过）
/// - `CODEX_SPIKE_PORT`：SSH 端口（默认 22）
/// - `CODEX_SPIKE_USER`：SSH 用户名
/// - `CODEX_SPIKE_KEY_PATH`：ed25519 私钥文件路径（OpenSSH PEM）
/// - `CODEX_SPIKE_KEY_PASSPHRASE`：私钥口令（可选）
///
/// 缺少必需变量时直接 `throw XCTSkip(...)`，因此常规 `xcodebuild test` 不需要凭证、
/// 不受影响。运行验证留给主会话（注入环境变量 + 临时密钥）。
final class SpikeIntegrationTests: XCTestCase {

    private struct SpikeConfig {
        let host: String
        let port: Int
        let user: String
        let keyPath: String
        let passphrase: String?
    }

    /// 从环境变量装配连接参数；任一必需项缺失则返回 nil（调用方据此跳过）。
    private func loadConfig() -> SpikeConfig? {
        let env = ProcessInfo.processInfo.environment
        func value(_ key: String) -> String? {
            guard let v = env[key], !v.isEmpty else { return nil }
            return v
        }
        guard
            let host = value("CODEX_SPIKE_HOST"),
            let user = value("CODEX_SPIKE_USER"),
            let keyPath = value("CODEX_SPIKE_KEY_PATH")
        else { return nil }

        let port = value("CODEX_SPIKE_PORT").flatMap(Int.init) ?? 22
        return SpikeConfig(
            host: host,
            port: port,
            user: user,
            keyPath: keyPath,
            passphrase: value("CODEX_SPIKE_KEY_PASSPHRASE")
        )
    }

    func testWithExecInitializeHandshakeAgainstRealServer() async throws {
        guard let config = loadConfig() else {
            throw XCTSkip("未提供 spike 连接参数（设置 CODEX_SPIKE_HOST/USER/KEY_PATH 后再跑）")
        }

        // 读 ed25519 私钥文件内容（OpenSSH PEM 文本）。鉴权走
        // SSHClientWrapper 的 .ed25519 分支：内部用
        // Curve25519.Signing.PrivateKey(sshEd25519:decryptionKey:) 解析，
        // 再 SSHAuthenticationMethod.ed25519(username:privateKey:)。
        let pem = try String(contentsOfFile: config.keyPath, encoding: .utf8)

        // 建 SSH → exec `codex app-server --listen stdio://` → 得到换行分帧的双向传输。
        let transport = try await SSHClientWrapper.connect(
            host: config.host,
            sshPort: config.port,
            auth: .ed25519(user: config.user, pem: pem, passphrase: config.passphrase)
        )

        // 失败/结束都要关闭通道，避免悬挂的 SSH exec。
        defer { Task { await transport.close() } }

        // 先订阅 incoming，再发 initialize，避免响应早于订阅丢失。
        let incoming = transport.incoming()

        let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"CodexRemote-IntegrationTest","title":null,"version":"0.0.1"},"capabilities":null}}"#
        try await transport.send(initialize)

        // 带超时读取首条完整 JSON 响应帧。
        let response = try await firstLine(from: incoming, timeout: 30)

        XCTAssertTrue(
            response.contains("userAgent"),
            "initialize 响应应含 userAgent，实际：\(response.prefix(400))"
        )
        XCTAssertTrue(
            response.contains("codexHome"),
            "initialize 响应应含 codexHome，实际：\(response.prefix(400))"
        )
    }

    /// 从 incoming 流取第一帧，超过 timeout 秒抛错（避免测试无限挂起）。
    private func firstLine(
        from stream: AsyncThrowingStream<String, Error>,
        timeout seconds: Double
    ) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                for try await line in stream {
                    return line
                }
                throw IntegrationError.streamEndedBeforeResponse
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw IntegrationError.timeout
            }
            guard let first = try await group.next() else {
                throw IntegrationError.streamEndedBeforeResponse
            }
            group.cancelAll()
            return first
        }
    }

    private enum IntegrationError: Error {
        case timeout
        case streamEndedBeforeResponse
    }
}
