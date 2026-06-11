// ⚠️ SPIKE 代码（Task 3）——临时验证 Citadel exec 通道 stdio 收发换行分隔 JSON，后续可删。
//
// Citadel 0.12.1 真实 API（已读源码确认，供 Task 6/7 复用）：
//   - exec 双向 stdio 用 `SSHClient.withExec(_:environment:perform:)`
//     （Sources/Citadel/TTY/Client/TTY.swift:455）。它走 RFC 4254 exec 通道，
//     8-bit safe（无 PTY 转义处理），正适合透传 JSON-RPC 字节流。
//   - perform 闭包签名：`(_ inbound: TTYOutput, _ outbound: TTYStdinWriter) async throws -> Void`
//   - inbound 是 `TTYOutput`（AsyncSequence，元素 `ExecCommandOutput`：.stdout(ByteBuffer)/.stderr(ByteBuffer)）
//   - outbound 是 `TTYStdinWriter`，`func write(_ buffer: ByteBuffer) async throws` 写 stdin
//   - withExec 在闭包返回 / 抛错后会自动 close 通道；闭包退出即结束 exec。
//
// 因为 inbound/outbound 仅在 withExec 的 perform 闭包内有效，本帮手把
// 「写一行 + 按换行读回首条完整 JSON」的逻辑做成可在闭包内复用的静态方法，
// 调用方（SpikeRunner）在闭包内串起整个 initialize→initialized 握手。

import Foundation
import Citadel
import NIOCore

@available(macOS 15.0, *)
enum SpikeWire {
    /// 经 exec 通道 stdin 写出一行 payload（自动补换行）。
    static func writeLine(_ payload: String, to outbound: TTYStdinWriter) async throws {
        let line = payload.hasSuffix("\n") ? payload : payload + "\n"
        try await outbound.write(ByteBuffer(string: line))
    }

    /// 从 inbound 流持续读取 stdout，按换行切分，返回第一条非空完整 JSON 行。
    /// stderr 仅记录不阻断（远端 codex 可能往 stderr 打日志）。
    /// 注意：调用前应已写出请求；本方法会一直读到出现换行或流结束。
    static func readFirstLine(
        from inbound: TTYOutput,
        stderrSink: (String) -> Void = { _ in }
    ) async throws -> String {
        var pending = Data()
        for try await chunk in inbound {
            switch chunk {
            case .stderr(let buffer):
                if let s = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) {
                    stderrSink(s)
                }
            case .stdout(let buffer):
                if let bytes = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes) {
                    pending.append(contentsOf: bytes)
                }
                if let newlineIndex = pending.firstIndex(of: 0x0A) {
                    let lineData = pending[pending.startIndex..<newlineIndex]
                    let line = String(decoding: lineData, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !line.isEmpty {
                        return line
                    }
                    // 空行，丢弃换行后继续
                    pending.removeSubrange(pending.startIndex...newlineIndex)
                }
            }
        }
        throw SpikeWireError.streamEndedBeforeResponse
    }
}

enum SpikeWireError: Error, CustomStringConvertible {
    case streamEndedBeforeResponse
    var description: String {
        switch self {
        case .streamEndedBeforeResponse:
            return "exec 通道在收到首条响应前就结束了（远端命令可能未启动或立即退出）"
        }
    }
}
