import Foundation

/// 收发原始 JSON 文本帧的抽象。真实实现走 `codex app-server --listen stdio://` exec 的 stdio（换行分隔），测试用 mock。
protocol MessageTransport: Sendable {
    /// 发送一条完整 JSON 文本帧（实现负责补换行）。
    func send(_ text: String) async throws
    /// 持续产出收到的每一条 JSON 文本帧，直到连接关闭。
    func incoming() -> AsyncThrowingStream<String, Error>
    func close() async
}
