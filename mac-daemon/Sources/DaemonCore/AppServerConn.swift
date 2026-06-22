import Foundation

/// 持有**唯一一条** `codex app-server --listen stdio://` 连接的 actor。
///
/// - spawn 一个 codex app-server 子进程,独占其 stdin/stdout。
/// - read loop:stdout 字节流经 `LineFramer` 切成 NDJSON 行,每行经 `onLine` 回调交给 Hub(payload 不透明)。
/// - `send`:把下游请求写进 app-server stdin。
/// - 崩溃自愈:子进程异常退出 → 广播一条状态事件 → 带退避重启;`shutdown()` 后不再自愈。
///
/// ⚠️ 进程安全:只通过自己持有的 `Process` 对象 terminate 自己 spawn 的那一个子进程。
/// 绝不使用 `pkill`/`killall` 等宽匹配(会误杀 desktop GUI 的 codex app-server)。
public actor AppServerConn {
    /// 每条完整 NDJSON 行(不含换行符)的回调。也用于广播自愈状态事件。
    public typealias LineHandler = @Sendable (Data) -> Void

    private let command: String
    private let arguments: [String]
    private let onLine: LineHandler
    /// 连续崩溃重启的退避上限(秒)。
    private let maxBackoff: Double

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var outHandle: FileHandle?
    private var framer = LineFramer()
    private var stopping = false
    /// 连续未收到任何输出就崩溃的次数,用于重启退避;一旦收到数据即清零。
    private var consecutiveFailures = 0

    /// - Parameters:
    ///   - command: 可执行名(经 `/usr/bin/env` 按 PATH 解析),默认 `codex`。
    ///   - arguments: 子命令参数,默认 `app-server --listen stdio://`。
    ///   - maxBackoff: 自愈重启退避上限秒数,默认 5。
    ///   - onLine: 每条 app-server 输出行的回调。
    public init(command: String = "codex",
                arguments: [String] = ["app-server", "--listen", "stdio://"],
                maxBackoff: Double = 5.0,
                onLine: @escaping LineHandler) {
        self.command = command
        self.arguments = arguments
        self.maxBackoff = maxBackoff
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
        teardownCurrent()
    }

    // MARK: - 内部

    /// 清理当前连接持有的句柄/进程(重启或关闭前调用),避免句柄泄漏与旧 handler 残留。
    private func teardownCurrent() {
        outHandle?.readabilityHandler = nil
        process?.terminate()   // 仅终止本对象持有的子进程,绝不宽匹配
        outHandle = nil
        stdinHandle = nil
        process = nil
    }

    private func spawn() throws {
        // 先清理上一个连接(重启自愈时旧 pipe/handler 必须释放)。
        teardownCurrent()

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
        consecutiveFailures = 0   // 收到数据即视为连接健康
        for line in framer.feed(data) {
            onLine(line)
        }
    }

    private func handleTermination() async {
        guard !stopping else { return }
        consecutiveFailures += 1
        // 广播状态事件,告知下游 app-server 重启。
        let notice = Data(#"{"method":"daemon/appServerRestarted","params":{}}"#.utf8)
        onLine(notice)
        // 退避:连续崩溃(未收到任何输出就退出)时拉长重启间隔,避免无限重启风暴。
        let delay = min(Double(consecutiveFailures), maxBackoff)
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        guard !stopping else { return }   // 退避期间可能已被 shutdown
        try? spawn()
    }
}
