import Foundation
import Observation

/// 下边栏终端会话：常驻 PTY shell 生命周期 + outputDelta 消费 + 输出缓冲。
@Observable
@MainActor
final class TerminalSession {
    private(set) var runs: [ANSIParser.Run] = []
    private(set) var processId: String?
    private(set) var running = false

    private var parser = ANSIParser()
    private var rpc: JSONRPCClient?
    private var observer: Task<Void, Never>?

    /// 复用①传输：订阅 outputDelta。幂等。
    func attach(rpc: JSONRPCClient) async {
        self.rpc = rpc
        guard observer == nil else { return }
        let stream = await rpc.notifications()
        observer = Task { [weak self] in
            for await n in stream { await MainActor.run { self?.applyBroadcast(n) } }
        }
    }

    /// 起常驻 zsh PTY。生成连接级 processId。无 rpc（单测）仅置本地态。
    func start(cwd: String?, size: CommandExecTerminalSize = .init(rows: 24, cols: 80)) {
        let pid = UUID().uuidString
        processId = pid
        parser = ANSIParser()
        running = true
        guard let rpc else { return }
        let params = CommandExecParams(command: ["/bin/zsh", "-i"], processId: pid, tty: true,
                                       streamStdin: true, streamStdoutStderr: true, cwd: cwd, size: size)
        Task { await send(RPCMethod.commandExec, params) }
        _ = rpc
    }

    func makeWriteParams(input: String) -> CommandExecWriteParams? {
        guard let pid = processId else { return nil }
        return CommandExecWriteParams(processId: pid, deltaBase64: Data(input.utf8).base64EncodedString(), closeStdin: nil)
    }
    func sendInput(_ input: String) {
        guard let p = makeWriteParams(input: input) else { return }
        Task { await send(RPCMethod.commandExecWrite, p) }
    }
    func resize(_ size: CommandExecTerminalSize) {
        guard let pid = processId else { return }
        Task { await send(RPCMethod.commandExecResize, CommandExecResizeParams(processId: pid, size: size)) }
    }
    func terminate() {
        guard let pid = processId else { return }
        Task { await send(RPCMethod.commandExecTerminate, CommandExecTerminateParams(processId: pid)) }
        running = false
    }

    /// internal 供单测：消费 outputDelta（仅匹配当前 processId）。
    func handleOutputDelta(processId pid: String, base64: String) {
        guard pid == processId, let data = Data(base64Encoded: base64) else { return }
        let text = String(decoding: data, as: UTF8.self)
        runs.append(contentsOf: parser.feed(text))
    }
    /// 断线：标失效 + 插断点行（保留历史）。
    func handleDisconnect() {
        running = false
        processId = nil
        runs.append(ANSIParser.Run(text: "\n── 连接断开，已重连 ──\n", color: .gray, bold: false))
    }

    private func applyBroadcast(_ n: JSONRPCNotification) {
        guard n.method == ServerNotificationMethod.commandExecOutputDelta,
              let p = n.params?.value as? [String: Any],
              let pid = p["processId"] as? String, let b64 = p["deltaBase64"] as? String else { return }
        handleOutputDelta(processId: pid, base64: b64)
    }
    private func send<T: Encodable>(_ method: String, _ params: T) async {
        guard let rpc, let d = try? JSONEncoder().encode(params),
              let any = try? JSONDecoder().decode(AnyCodable.self, from: d) else { return }
        _ = try? await rpc.send(method: method, params: any)
    }
}
