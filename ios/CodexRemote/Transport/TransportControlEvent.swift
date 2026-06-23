import Foundation

/// 传输层控制信号（与 send/incoming/close 正交）：
/// 仅承载「会话语义」事件，供 ConnectionStore 驱动 UI 与会话重建。
enum TransportControlEvent: Sendable, Equatable {
    case reconnecting      // ws 抖动，正在内部重连（UI 显示重连中）
    case ready             // 重连成功，已发 resync
    case snapshotNeeded    // 缺口过大，需 ConversationStore.resume() 重建
}
