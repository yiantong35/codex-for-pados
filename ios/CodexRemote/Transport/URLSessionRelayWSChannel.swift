import Foundation

/// `URLSessionWebSocketTask` 的可注入抽象：单测注入假 task 覆盖收发/关闭行为，不触真网络。
/// `URLSessionWebSocketTask` 原生就有这些 async 方法，空扩展即可 conform。
protocol WebSocketTaskProtocol: Sendable {
    func resume()
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
}
extension URLSessionWebSocketTask: WebSocketTaskProtocol {}

/// 生产 ws 通道：包 `URLSessionWebSocketTask`，实现 `RelayWSChannel`。
/// actor 收敛对 task 的并发访问（满足 `Sendable`），一条 text frame = 一条 SecureEnvelope JSON。
actor URLSessionRelayWSChannel: RelayWSChannel {
    private let task: WebSocketTaskProtocol
    private var closed = false

    init(task: WebSocketTaskProtocol) {
        self.task = task
        task.resume()
    }

    func sendText(_ text: String) async throws {
        if closed { throw TransportError.channelClosed(reason: "通道已关闭") }
        do {
            try await task.send(.string(text))
        } catch {
            closed = true
            throw TransportError.channelClosed(reason: "ws 发送失败: \(error)")
        }
    }

    func receiveText() async throws -> String? {
        while true {
            if closed { return nil }
            do {
                switch try await task.receive() {
                case .string(let s): return s
                case .data:          continue          // 忽略二进制帧，继续收下一条 text
                @unknown default:    continue
                }
            } catch {
                // 关闭/取消/网络失败：作流结束（nil）。握手期调用方 receiveText()==nil 会抛明确错误落 .failed。
                closed = true
                return nil
            }
        }
    }

    func close() async {
        closed = true
        task.cancel(with: .normalClosure, reason: nil)
    }
}
