import Foundation

/// 桥接开发机本地已有的共享 control-socket daemon。
///
/// spawn 官方 `codex app-server proxy --sock <control.sock>` 子进程——**只 spawn proxy 桥**，
/// 不自 spawn app-server（daemon 已由 desktop/首连接起好，proxy 幂等接入，保真跨端同步）。
///
/// stdin/stdout 走 Pipe：`write` 往 proxy stdin 按行写；`incoming` 按行读 proxy stdout。
///
/// ⚠️ 进程安全：只记住并管理**自己 spawn 的这个子进程 PID**，`terminate()` 仅停它，
/// 绝不使用 pkill/wide-match kill（会误杀 desktop GUI 私有的 app-server）。
public final class ProxyBridge {
    private let codexPath: String
    private let sockPath: String
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()

    /// - Parameters:
    ///   - codexPath: 可执行路径，允许注入便于测试用无害 stub（默认 "codex"）。
    ///   - sockPath: control-socket 路径。
    public init(codexPath: String = "codex", sockPath: String) {
        self.codexPath = codexPath
        self.sockPath = sockPath
    }

    /// 我方 spawn 的子进程 PID（仅在 start 后有效），用于确认只管自己这一个。
    public var pid: Int32 { process.processIdentifier }

    public func start() throws {
        process.executableURL = URL(fileURLWithPath: codexPath)
        process.arguments = ["app-server", "proxy", "--sock", sockPath]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        try process.run()
    }

    /// 往 proxy stdin 写一行 JSON-RPC（按行协议，自动补换行）。
    public func write(_ jsonrpc: String) {
        let line = jsonrpc.hasSuffix("\n") ? jsonrpc : jsonrpc + "\n"
        if let data = line.data(using: .utf8) {
            stdinPipe.fileHandleForWriting.write(data)
        }
    }

    /// 行缓冲：包成引用类型，满足 Swift6 并发闭包的 Sendable 捕获约束。
    private final class LineBuffer: @unchecked Sendable {
        var data = Data()
    }

    /// 按行读 proxy stdout，每完整行 yield 一次（裸 JSON-RPC）。
    public var incoming: AsyncStream<String> {
        AsyncStream { continuation in
            let handle = stdoutPipe.fileHandleForReading
            let buffer = LineBuffer()
            handle.readabilityHandler = { fh in
                let chunk = fh.availableData
                if chunk.isEmpty {
                    // EOF：flush 残余并结束流。
                    if !buffer.data.isEmpty, let s = String(data: buffer.data, encoding: .utf8) {
                        continuation.yield(s)
                    }
                    handle.readabilityHandler = nil
                    continuation.finish()
                    return
                }
                buffer.data.append(chunk)
                while let nl = buffer.data.firstIndex(of: 0x0A) {
                    let lineData = buffer.data[buffer.data.startIndex..<nl]
                    if let s = String(data: lineData, encoding: .utf8) {
                        continuation.yield(s)
                    }
                    buffer.data.removeSubrange(buffer.data.startIndex...nl)
                }
            }
            continuation.onTermination = { _ in
                handle.readabilityHandler = nil
            }
        }
    }

    /// 只停自己 spawn 的这个子进程（精确 PID），绝不 pkill。
    public func terminate() {
        if process.isRunning {
            process.terminate()
        }
    }
}
