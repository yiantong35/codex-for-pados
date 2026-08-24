import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum DaemonBridgeError: Error, Equatable {
    case executableNotFound(String)
}

/// 自 spawn 并持有开发机本地一个 `codex app-server --listen stdio://` daemon，做 stdin/stdout 裸行直管道。
///
/// relay-only 架构下不存在可接入的共享 control-socket daemon（desktop Electron GUI 跑不可接入的私有
/// stdio daemon，默认 `~/.codex/control.sock` 不存在），故本桥自 spawn 一个单客户端 stdio daemon 作桥接目标，
/// 绝不接管任何外部已存在 daemon、绝不使用 `app-server proxy`。stdio 无监听端口 = 天然单客户端、零网络暴露面。
///
/// stdin/stdout 走 Pipe：`write` 往 daemon stdin 按行写；`incoming` 按行读 daemon stdout（裸行 JSON-RPC）。
///
/// ⚠️ 进程安全：只记住并管理**自己 spawn 的这个子进程 PID**，`terminate()` 仅停它，
/// 绝不使用 pkill/wide-match kill（会误杀 desktop GUI 私有的 app-server）。
public final class DaemonBridge: @unchecked Sendable {
    private let codexPath: String
    private let overrideArguments: [String]?
    private let environment: [String: String]
    private let overrideWorkingDirectory: URL?
    private let terminationGracePeriod: Duration
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let processQueue = DispatchQueue(label: "com.codexremote.relay-dialout.daemon-process")
    private let writerQueue = DispatchQueue(label: "com.codexremote.relay-dialout.daemon-stdin")
    private let writerLock = NSLock()
    private let maximumPendingWriteBytes: Int
    private var pendingWrites: [Data] = []
    private var pendingWriteBytes = 0
    private var writerScheduled = false
    private var didStart = false

    /// - Parameters:
    ///   - codexPath: 可执行路径，允许注入便于测试用无害 stub（默认 "codex"）。
    ///   - arguments: 子进程参数，默认 nil→生产固定为 `["app-server","--listen","stdio://"]`；
    ///     仅测试可注入长驻无害 stub 参数（如 `/bin/sleep 300`）验证 terminate 回收，**不改生产调用路径**。
    public init(codexPath: String = "codex",
                arguments: [String]? = nil,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                workingDirectory: URL? = nil,
                maximumPendingWriteBytes: Int = 4 * 1024 * 1024,
                terminationGracePeriod: Duration = .seconds(2)) {
        self.codexPath = codexPath
        self.overrideArguments = arguments
        self.environment = environment
        self.overrideWorkingDirectory = workingDirectory
        self.maximumPendingWriteBytes = max(1, maximumPendingWriteBytes)
        self.terminationGracePeriod = terminationGracePeriod
    }

    /// 我方 spawn 的子进程 PID（仅在 start 后有效），用于确认只管自己这一个。
    public var pid: Int32 { processQueue.sync { process.processIdentifier } }

    /// 自己持有的这个子进程是否仍在运行（仅反映自身 `process` 句柄，非按名查找）。
    public var isRunning: Bool { processQueue.sync { process.isRunning } }

    /// start() 实际会用的参数：生产固定 spawn `codex app-server --listen stdio://`，
    /// 仅测试注入时用 override。暴露为只读属性，便于单测断言而不必真的 spawn daemon。
    var resolvedArguments: [String] {
        overrideArguments ?? ["app-server", "--listen", "stdio://"]
    }

    /// start() 实际会设的子进程工作目录:默认用户家目录(中性、稳定、非源码目录、无写副作用),
    /// 仅测试可注入覆盖以做属性断言,不改生产调用路径。会话显式带 cwd 时以 per-thread cwd 为准,本目录仅兜底。
    /// 注:兜底路径下(会话未带 cwd 时)app-server 若向相对路径写文件,落点为 $HOME;当前设计中会话均显式带 cwd,风险很低。
    var resolvedWorkingDirectory: URL {
        overrideWorkingDirectory ?? FileManager.default.homeDirectoryForCurrentUser
    }

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
            process.arguments = resolvedArguments
            process.environment = environment
            process.currentDirectoryURL = resolvedWorkingDirectory   // D3:显式设中性 cwd,子进程不再继承拨出程序启动目录
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
                throw DaemonBridgeError.executableNotFound(configuredPath)
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
        throw DaemonBridgeError.executableNotFound(configuredPath)
    }

    /// 往 daemon stdin 写一行 JSON-RPC（按行协议，自动补换行）。
    @discardableResult
    public func write(_ jsonrpc: String) -> Bool {
        let line = jsonrpc.hasSuffix("\n") ? jsonrpc : jsonrpc + "\n"
        guard let data = line.data(using: .utf8) else { return false }
        writerLock.lock()
        guard data.count <= maximumPendingWriteBytes - pendingWriteBytes else {
            writerLock.unlock()
            return false
        }
        pendingWrites.append(data)
        pendingWriteBytes += data.count
        let shouldSchedule = !writerScheduled
        writerScheduled = true
        writerLock.unlock()
        if shouldSchedule { writerQueue.async { [self] in drainWrites() } }
        return true
    }

    private func drainWrites() {
        while true {
            writerLock.lock()
            guard !pendingWrites.isEmpty else {
                writerScheduled = false
                writerLock.unlock()
                return
            }
            let data = pendingWrites.removeFirst()
            pendingWriteBytes -= data.count
            writerLock.unlock()
            do {
                try stdinPipe.fileHandleForWriting.write(contentsOf: data)
            } catch {
                writerLock.lock()
                pendingWrites.removeAll()
                pendingWriteBytes = 0
                writerScheduled = false
                writerLock.unlock()
                return
            }
        }
    }

    /// 行缓冲：包成引用类型，满足 Swift6 并发闭包的 Sendable 捕获约束。
    private final class LineBuffer: @unchecked Sendable {
        var data = Data()
    }

    /// 按行读 daemon stdout，每完整行 yield 一次（裸 JSON-RPC）。
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
