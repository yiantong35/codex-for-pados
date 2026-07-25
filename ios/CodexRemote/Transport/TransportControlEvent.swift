import Foundation

/// 传输层控制信号（与 send/incoming/close 正交）：
/// 仅承载重连/ready 语义，供 ConnectionStore 驱动 UI。
/// 去 envelope 后无 seq 缺口概念，故移除 snapshotNeeded。
enum TransportControlEvent: Sendable, Equatable {
    case reconnecting      // ws 抖动，正在内部重连（UI 显示重连中）
    case ready             // 重连成功
    case connectionFailed  // 退避重试达上限仍失败 = 终态（保留机器待手动重连）
    case trustRevoked      // 收到 RejectHello（信任被撤销）= 终态（引导重新配对）
}
