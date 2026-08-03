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
    /// 前台/后台状态钩子（能耗）：后台可暂停重连等高耗操作，回前台恢复。有默认空实现。
    func setForeground(_ active: Bool) async
    /// 心跳判死后主动触发一次内部有界重连（默认无重连能力的 transport 为 no-op）。
    func triggerReconnect() async
}

extension MessageTransport {
    /// 控制信号通道默认实现：无控制信号的 transport（如 MockTransport）返回空流。
    /// 具备物理重连能力的 transport 可覆写以上报 reconnecting/ready（SSH 重连属 Phase 5）。
    func control() -> AsyncStream<TransportControlEvent> {
        AsyncStream { $0.finish() }
    }

    /// 默认：无独立 ws 握手阶段的 transport 立即返回。
    func awaitHandshake() async throws { }

    /// 默认：无重连能耗管理的 transport（MockTransport）忽略前台/后台切换。
    /// 具备物理重连能力的 transport（RelayTransport）可覆写以在后台暂停重连。
    func setForeground(_ active: Bool) async { }

    /// 默认：无内部重连能力的 transport（MockTransport 等）为 no-op。
    /// 具备有界重连的 transport（RelayTransport）可覆写以主动丢弃当前通道触发重连。
    func triggerReconnect() async { }
}
