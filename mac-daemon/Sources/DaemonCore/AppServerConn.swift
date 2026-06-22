import Foundation

/// 持有**唯一一条** `codex app-server --listen stdio://` 连接的 actor。
///
/// - spawn 一个 codex app-server 子进程,独占其 stdin/stdout。
/// - read loop:stdout 字节流经 `LineFramer` 切成 NDJSON 行,每行经 `onLine` 回调交给 Hub(payload 不透明)。
/// - `send`:把下游请求写进 app-server stdin。
/// - 崩溃自愈:子进程异常退出 → 广播一条状态事件 → 重启;`shutdown()` 后不再自愈。
///
/// ⚠️ 进程安全:只通过自己持有的 `Process` 对象 terminate 自己 spawn 的那一个子进程。
/// 绝不使用 `pkill`/`killall` 等宽匹配(会误杀 desktop GUI 的 codex app-server)。
public actor AppServerConn {
    /// 每条完整 NDJSON 行(不含换行符)的回调。也用于广播自愈状态事件。
    public typealias LineHandler = @Sendable (Data) -> Void

    private let command: String
    private let arguments: [String]
    private let onLine: LineHandler

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var outHandle: FileHandle?
    private var framer = LineFramer()
    private var stopping = false

    /// - Parameters:
    ///   - command: 可执行名(经 `/usr/bin/env` 按 PATH 解析),默认 `codex`。
    ///   - arguments: 子命令参数,默认 `app-server --listen stdio://`。
    ///   - onLine: 每条 app-server 输出行的回调。
    public init(command: String = "codex",
                arguments: [String] = ["app-server", "--listen", "stdio://"],
                onLine: @escaping LineHandler) {
        self.command = command
        self.arguments = arguments
        self.onLine = onLine
    }

    /// 启动并持有 app-server 连接。
    public func start() throws {
        try spawn()
    }

    /// 把请求 payload 写入 app-server stdin(自动补 `\n`)。
    public func send(_ payload: Data) {
        guard let h = stdinHandle else { return }
        var d = payload
        if d.last != 0x0A { d.append(0x0A) }
        try? h.write(contentsOf: d)
    }

    /// 优雅关闭:停止自愈,只 terminate 自己 spawn 的子进程。
    public func shutdown() {
        stopping = true
        outHandle?.readabilityHandler = nil
        process?.terminate()   // 仅终止本对象持有的子进程,绝不宽匹配
        outHandle = nil
        stdinHandle = nil
        process = nil
    }

    // MARK: - 内部

    private func spawn() throws {
        let proc = Process()
        // 经 /usr/bin/env 按 PATH 解析 codex,避免硬编码绝对路径。
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = [command] + arguments

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        // stderr 继承父进程(用于诊断),不接管。

        let out = stdoutPipe.fileHandleForReading
        out.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }   // 空 = EOF
            Task { await self.ingest(data) }
        }

        proc.terminationHandler = { [weak self] _ in
            guard let self else { return }
            Task { await self.handleTermination() }
        }

        try proc.run()

        self.process = proc
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.outHandle = out
        self.framer = LineFramer()   // 新连接重置行缓冲
    }

    private func ingest(_ data: Data) {
        for line in framer.feed(data) {
            onLine(line)
        }
    }

    private func handleTermination() {
        guard !stopping else { return }
        // 子进程异常退出:先广播状态事件,再重启(自愈)。
        let notice = Data(#"{"method":"daemon/appServerRestarted","params":{}}"#.utf8)
        onLine(notice)
        try? spawn()
    }
}
