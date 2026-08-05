import Foundation
import Observation

/// 下边栏终端会话：常驻 PTY shell 生命周期 + outputDelta 消费 + 输出缓冲。
@Observable
@MainActor
final class TerminalSession {
    /// 原始输出字节发布点：SwiftTermView 的 Coordinator 注入，在主线程 feed(byteArray:)。
    /// @ObservationIgnored 避免赋值触发视图刷新。
    @ObservationIgnored var onBytes: (([UInt8]) -> Void)?

    /// 测试观察点：sendInput/resize 的入参镜像（生产为 nil，无副作用）。
    @ObservationIgnored var onInputForTest: ((String) -> Void)?
    @ObservationIgnored var onResizeForTest: ((CommandExecTerminalSize) -> Void)?

    private(set) var processId: String?
    private(set) var running = false
    private var startedCwd: String?     // 当前 shell 绑定的 cwd（用于跟随判定）

    private var rpc: JSONRPCClient?
    private var observer: Task<Void, Never>?

    /// 复用①传输：订阅 outputDelta。幂等；完整重连换新 rpc 实例时——
    ///   ① 取消旧订阅并对新 rpc 重订阅（否则 guard==nil 挡住重订阅 → 新连接 shell 输出永不显示）；
    ///   ② stale processId 复位：旧 pid 属已断连接上的 shell，新连接无此进程，保留会令
    ///      startIfNeeded 同 cwd 误判「已运行」而跳过重起（终端永久空白）。复位后由 startIfNeeded 重起。
    func attach(rpc: JSONRPCClient) async {
        let rpcChanged = self.rpc !== rpc
        self.rpc = rpc
        if rpcChanged {
            observer?.cancel(); observer = nil
            processId = nil; startedCwd = nil; running = false   // ② stale 复位
        }
        guard observer == nil else { return }
        let stream = await rpc.notifications()
        observer = Task { [weak self] in
            for await n in stream { await MainActor.run { self?.applyBroadcast(n) } }
        }
    }

    /// cwd 跟随：未起 或 cwd 变化时(重)起 shell；同 cwd 已运行则跳过。
    func startIfNeeded(cwd: String?) {
        if processId != nil && startedCwd == cwd { return }
        if processId != nil { terminate() }   // 切会话：终止旧 shell 再起新的
        start(cwd: cwd)
    }

    /// 起常驻 zsh PTY。生成连接级 processId。无 rpc（单测）仅置本地态。
    func start(cwd: String?, size: CommandExecTerminalSize = .init(rows: 24, cols: 80)) {
        let pid = UUID().uuidString
        processId = pid
        startedCwd = cwd
        running = true
        guard let rpc else { return }
        let params = CommandExecParams(command: ["/bin/zsh", "-i"], processId: pid, tty: true,
                                       streamStdin: true, streamStdoutStderr: true, cwd: cwd, size: size)
        Task { await send(RPCMethod.commandExec, params) }
    }

    func makeWriteParams(input: String) -> CommandExecWriteParams? {
        guard let pid = processId else { return nil }
        return CommandExecWriteParams(processId: pid, deltaBase64: Data(input.utf8).base64EncodedString(), closeStdin: nil)
    }
    func sendInput(_ input: String) {
        onInputForTest?(input)
        guard let p = makeWriteParams(input: input) else { return }
        Task { await send(RPCMethod.commandExecWrite, p) }
    }
    func resize(_ size: CommandExecTerminalSize) {
        onResizeForTest?(size)
        guard let pid = processId else { return }
        Task { await send(RPCMethod.commandExecResize, CommandExecResizeParams(processId: pid, size: size)) }
    }
    func terminate() {
        guard let pid = processId else { return }
        Task { await send(RPCMethod.commandExecTerminate, CommandExecTerminateParams(processId: pid)) }
        running = false
    }

    /// internal 供单测：消费 outputDelta（仅匹配当前 processId）。字节直发给 SwiftTerm。
    func handleOutputDelta(processId pid: String, base64: String, capReached: Bool = false) {
        guard pid == processId, let data = Data(base64Encoded: base64) else { return }
        onBytes?([UInt8](data))
        if capReached {
            onBytes?([UInt8]("\r\n── 输出已截断（超出上限）──\r\n".utf8))
        }
    }
    /// 断线：标失效 + 插断点行（终端语义换行 \r\n）。
    func handleDisconnect() {
        running = false
        processId = nil
        onBytes?([UInt8]("\r\n── 连接断开，已重连 ──\r\n".utf8))
    }

    private func applyBroadcast(_ n: JSONRPCNotification) {
        guard n.method == ServerNotificationMethod.commandExecOutputDelta,
              let p = n.params?.value as? [String: Any],
              let pid = p["processId"] as? String, let b64 = p["deltaBase64"] as? String else { return }
        handleOutputDelta(processId: pid, base64: b64, capReached: (p["capReached"] as? Bool) ?? false)
    }
    private func send<T: Encodable>(_ method: String, _ params: T) async {
        guard let rpc, let d = try? JSONEncoder().encode(params),
              let any = try? JSONDecoder().decode(AnyCodable.self, from: d) else { return }
        _ = try? await rpc.send(method: method, params: any)
    }
}
