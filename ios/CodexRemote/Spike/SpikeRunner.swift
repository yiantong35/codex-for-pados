// ⚠️ SPIKE 代码（Task 3）——临时验证逻辑，后续可删。
//
// ============================================================================
// Citadel 0.12.1 真实 exec API 形状（已读 SPM checkout 源码确认，供 Task 6/7 复用）
// ============================================================================
//
// 1) 建连：SSHClient.connect(host:port:authenticationMethod:hostKeyValidator:reconnect:...)
//      - Sources/Citadel/Client.swift:278
//      - authenticationMethod: SSHAuthenticationMethod（非 autoclosure 这个重载）
//        工厂：.passwordBased(username:password:) / .ed25519(...) / .rsa(...) 等
//      - hostKeyValidator: SSHHostKeyValidator，工厂 .acceptAnything() / .trustedKeys(_:)
//      - reconnect: SSHReconnectMode，静态属性 .never / .once / .always（注意是属性不是函数）
//
// 2) exec 双向 stdio：SSHClient.withExec(_:environment:perform:)
//      - Sources/Citadel/TTY/Client/TTY.swift:455
//      - RFC 4254 exec 通道，8-bit safe（无 PTY 转义处理），适合透传 JSON-RPC 字节
//      - perform: (_ inbound: TTYOutput, _ outbound: TTYStdinWriter) async throws -> Void
//          · inbound: TTYOutput（AsyncSequence，元素 ExecCommandOutput: .stdout/.stderr(ByteBuffer)）
//          · outbound: TTYStdinWriter，write(_ buffer: ByteBuffer) async throws → 写 stdin
//      - 闭包退出后 Citadel 自动 close 通道。
//      - ⚠️ 标了 @available(macOS 15.0, *)，但无 iOS 可用性下限标注；
//        Citadel Package.swift 平台为 .iOS(.v17)，本工程部署目标 iOS 17，
//        故在 iOS 上 withExec 全版本可用（本 spike 模拟器编译已验证此点）。
//
// ============================================================================
// 与计划 Task 3 伪代码的偏差
// ============================================================================
//   - 计划伪代码假设有 `executeCommandStream / withExecChannel` 之类并把
//     SpikeWire.sendAndAwaitFirstResponse(client:command:payload:) 设计成
//     在 client 上独立收发。真实 Citadel 不暴露「拿到长期 stdio 句柄再到处用」
//     的形态：inbound/outbound 只在 withExec 的 perform 闭包作用域内有效。
//   - 因此本 spike 把整个 initialize→读响应→initialized 握手都放进 withExec
//     闭包内顺序完成，用一个 box 把结果带出闭包。Task 7 的帧传输层需据此设计：
//     传输层应在 withExec 闭包内长驻（一个常驻 read loop + 一个 outbound 写句柄），
//     而非「随用随开 exec」。
//
// 当前状态：// SPIKE 代码就绪 + 模拟器编译通过 2026-06-11；真机 SSH 握手待用户验证
// ============================================================================

import Foundation
import Citadel
import NIOCore

@available(macOS 15.0, *)
struct SpikeRunner {
    /// box：在非 Sendable 的 withExec 闭包内写、闭包外读握手结果。
    /// 闭包同步顺序执行，无并发竞争。
    private final class ResultBox: @unchecked Sendable {
        var handshakeResponse: String?
        var stderrLog: String = ""
    }

    func run(host: String, sshPort: Int,
             user: String, password: String) async throws -> String {
        // 1) 建立 SSH 连接（密码鉴权，spike 简化；生产需固定/记录 host key）
        let client = try await SSHClient.connect(
            host: host,
            port: sshPort,
            authenticationMethod: .passwordBased(username: user, password: password),
            hostKeyValidator: .acceptAnything(),
            reconnect: .never
        )

        let box = ResultBox()

        // initialize 请求（换行结尾在 SpikeWire.writeLine 内补）
        let initialize = #"""
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"CodexRemote-Spike","title":null,"version":"0.0.1"},"capabilities":null}}
        """#
        // initialized 通知（无 id）
        let initialized = #"{"jsonrpc":"2.0","method":"initialized"}"#

        // 2) exec 远端 `codex app-server proxy`，在其 stdio 上完成握手。
        //    proxy 把 stdio 字节透明桥接到受管 daemon 的 control socket。
        try await client.withExec("codex app-server proxy") { inbound, outbound in
            // 写 initialize（含换行）
            try await SpikeWire.writeLine(initialize, to: outbound)
            // 读回首条完整 JSON 响应（应含 result：userAgent/codexHome 等）
            let response = try await SpikeWire.readFirstLine(
                from: inbound,
                stderrSink: { box.stderrLog += $0 }
            )
            box.handshakeResponse = response
            // 发 initialized 通知
            try await SpikeWire.writeLine(initialized, to: outbound)
            // 闭包退出 → Citadel close 通道。spike 只验证握手往返，不进入长连接读循环。
        }

        try? await client.close()

        guard let response = box.handshakeResponse else {
            throw SpikeWireError.streamEndedBeforeResponse
        }
        var result = "握手成功 ✅\n响应：\(response.prefix(400))"
        if !box.stderrLog.isEmpty {
            result += "\n[stderr]\(box.stderrLog.prefix(200))"
        }
        return result
    }
}
