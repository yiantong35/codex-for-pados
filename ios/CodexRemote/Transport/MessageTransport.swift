import Foundation

/// 收发原始 JSON 文本帧的抽象。真实实现走 `codex app-server --listen stdio://` exec 的 stdio（换行分隔），测试用 mock。
protocol MessageTransport: Sendable {
    /// 发送一条完整 JSON 文本帧（实现负责补换行）。
    func send(_ text: String) async throws
    /// 持续产出收到的每一条 JSON 文本帧，直到连接关闭。
    func incoming() -> AsyncThrowingStream<String, Error>
    func close() async
    /// 阻塞直到底层 ws 握手完成（收到 101 且 Accept 校验通过）；已完成则立即返回，握手失败则抛出。
    /// 无独立握手阶段的 transport（MockTransport）用默认空实现立即返回。
    func awaitHandshake() async throws
    /// 控制信号流（有默认空实现）。
    func control() -> AsyncStream<TransportControlEvent>
}

extension MessageTransport {
    /// 控制信号通道默认实现：无控制信号的 transport（如 MockTransport / 当前 ProxyChannel）返回空流。
    /// 具备物理重连能力的 transport 可覆写以上报 reconnecting/ready（SSH 重连属 Phase 5）。
    func control() -> AsyncStream<TransportControlEvent> {
        AsyncStream { $0.finish() }
    }

    /// 默认：无独立 ws 握手阶段的 transport 立即返回。
    func awaitHandshake() async throws { }
}
