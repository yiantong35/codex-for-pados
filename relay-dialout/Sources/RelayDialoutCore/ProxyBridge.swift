import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum ProxyBridgeError: Error, Equatable {
    case executableNotFound(String)
}

/// 桥接开发机本地已有的共享 control-socket daemon。
///
/// spawn 官方 `codex app-server proxy --sock <control.sock>` 子进程——**只 spawn proxy 桥**，
/// 不自 spawn app-server（daemon 已由 desktop/首连接起好，proxy 幂等接入，保真跨端同步）。
///
/// stdin/stdout 走 Pipe：`write` 往 proxy stdin 按行写；`incoming` 按行读 proxy stdout。
///
/// ⚠️ 进程安全：只记住并管理**自己 spawn 的这个子进程 PID**，`terminate()` 仅停它，
/// 绝不使用 pkill/wide-match kill（会误杀 desktop GUI 私有的 app-server）。
public final class ProxyBridge: @unchecked Sendable {
    private let codexPath: String
    private let sockPath: String
    private let overrideArguments: [String]?
    private let environment: [String: String]
    private let terminationGracePeriod: Duration
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let processQueue = DispatchQueue(label: "com.codexremote.relay-dialout.proxy-process")
    private var didStart = false

    /// - Parameters:
    ///   - codexPath: 可执行路径，允许注入便于测试用无害 stub（默认 "codex"）。
    ///   - arguments: 子进程参数，默认 nil→生产固定为 `["app-server","proxy","--sock",sockPath]`；
    ///     仅测试可注入长驻无害 stub 参数（如 `/bin/sleep 300`）验证 terminate 回收，**不改生产调用路径**。
    ///   - sockPath: control-socket 路径。
    public init(codexPath: String = "codex",
                arguments: [String]? = nil,
                sockPath: String,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                terminationGracePeriod: Duration = .seconds(2)) {
        self.codexPath = codexPath
        self.overrideArguments = arguments
        self.sockPath = sockPath
        self.environment = environment
        self.terminationGracePeriod = terminationGracePeriod
    }

    /// 我方 spawn 的子进程 PID（仅在 start 后有效），用于确认只管自己这一个。
    public var pid: Int32 { processQueue.sync { process.processIdentifier } }

    /// 自己持有的这个子进程是否仍在运行（仅反映自身 `process` 句柄，非按名查找）。
    public var isRunning: Bool { processQueue.sync { process.isRunning } }

    /// 非正常信号退出时的信号编号；仅在完成回收后有值。
    public var terminationSignal: Int32? {
        processQueue.sync {
            guard didStart, !process.isRunning, process.terminationReason == .uncaughtSignal else { return nil }
            return process.terminationStatus
        }
    }

    public func start() throws {
        try processQueue.sync {
            process.executableURL = try Self.resolveExecutable(codexPath, environment: environment)
            process.arguments = overrideArguments ?? ["app-server", "proxy", "--sock", sockPath]
            process.environment = environment
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            try process.run()
            didStart = true
        }
    }

    /// `Process.executableURL` 不会搜索 PATH；生产默认值 `codex` 必须先解析成绝对路径。
    static func resolveExecutable(_ configuredPath: String,
                                  environment: [String: String]) throws -> URL {
        let fileManager = FileManager.default
        if configuredPath.contains("/") {
            let url = URL(fileURLWithPath: configuredPath).standardizedFileURL
            guard fileManager.isExecutableFile(atPath: url.path) else {
                throw ProxyBridgeError.executableNotFound(configuredPath)
            }
            return url
        }

        let searchPath = environment["PATH"] ?? ""
        for component in searchPath.split(separator: ":", omittingEmptySubsequences: false) {
            let directory = component.isEmpty ? fileManager.currentDirectoryPath : String(component)
            let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(configuredPath)
                .standardizedFileURL
            if fileManager.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        throw ProxyBridgeError.executableNotFound(configuredPath)
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

    /// 非阻塞地发起精确回收：先向自己 spawn 的 PID 发 SIGTERM，宽限期后仍存活才发 SIGKILL。
    /// 实际等待与 reap 全在私有串行队列，调用本方法的 NIO EventLoop 不会被阻塞。
    public func terminate() {
        processQueue.async { [self] in
            guard didStart, process.isRunning else { return }
            process.terminate()

            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: terminationGracePeriod)
            while process.isRunning, clock.now < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning {
                _ = kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
        }
    }

    /// 等待此前排队的终止/reap 完成。只能在 EventLoop 外的顶层收口或测试代码调用。
    public func waitForTermination() {
        processQueue.sync {}
    }
}
