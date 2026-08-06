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
/// The dialout connection owner serializes lifecycle and stdin writes. Foundation's
/// Process/Pipe types do not declare Sendable even though stdout delivery crosses
/// into the AsyncStream task, so the ownership invariant is expressed explicitly.
public final class ProxyBridge: @unchecked Sendable {
    private let codexPath: String
    private let sockPath: String
    private let overrideArguments: [String]?
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()

    /// - Parameters:
    ///   - codexPath: 可执行路径，允许注入便于测试用无害 stub（默认 "codex"）。
    ///   - arguments: 子进程参数，默认 nil→生产固定为 `["app-server","proxy","--sock",sockPath]`；
    ///     仅测试可注入长驻无害 stub 参数（如 `/bin/sleep 300`）验证 terminate 回收，**不改生产调用路径**。
    ///   - sockPath: control-socket 路径。
    public init(codexPath: String = "codex", arguments: [String]? = nil, sockPath: String) {
        self.codexPath = codexPath
        self.overrideArguments = arguments
        self.sockPath = sockPath
    }

    /// 我方 spawn 的子进程 PID（仅在 start 后有效），用于确认只管自己这一个。
    public var pid: Int32 { process.processIdentifier }

    /// 自己持有的这个子进程是否仍在运行（仅反映自身 `process` 句柄，非按名查找）。
    public var isRunning: Bool { process.isRunning }

    public func start() throws {
        process.executableURL = URL(fileURLWithPath: codexPath)
        process.arguments = overrideArguments ?? ["app-server", "proxy", "--sock", sockPath]
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
    /// terminate 后同步等待其退出以回收（防僵尸）——仅等自己这一个 process 句柄，
    /// 是终止收尾的一次性同步等待（非轮询、非常驻线程；进程已被请求退出，等待即刻返回）。
    public func terminate() {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }
}
