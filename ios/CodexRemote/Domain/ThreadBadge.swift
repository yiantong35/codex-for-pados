import Foundation

/// 上次 turn 的结局（未读结局态用）。持久化到 ReadStateStore。
enum Outcome: String, Codable, Equatable {
    case failed
    case completed
}

/// 实时态：直接映射 app-server 的 ThreadStatus，随会话变化、不 view-gate（设计 D1）。
enum LiveStatus: Equatable {
    case none       // idle / notLoaded / 未知
    case running    // active（无等待 flag）/ turn inProgress → 橙脉冲
    case waiting    // active.activeFlags 含 waitingOnUserInput | waitingOnApproval → 蓝

    /// ThreadStatus 字符串 + activeFlags → 实时态（设计 D1，B10：两 flag 合并为单一 waiting）。
    static func from(threadStatus: String, activeFlags: [String]) -> LiveStatus {
        switch threadStatus {
        case "active":
            if activeFlags.contains("waitingOnUserInput")
                || activeFlags.contains("waitingOnApproval") {
                return .waiting
            }
            return .running
        default:
            // idle / notLoaded / systemError / 未知 → 实时态无（systemError 走未读结局态）
            return .none
        }
    }
}

/// 单一徽标仲裁结果。空闲且无未读 → .none（不渲染圆点）。
enum ThreadBadge: Equatable {
    case none
    case running          // 橙脉冲
    case waiting          // 蓝
    case unreadFailed     // 红
    case unreadCompleted  // 绿

    /// 零依赖纯函数：仲裁单一主导徽标（设计 D2）。
    /// 优先级：运行中 > 待处理 > 未读失败 > 未读完成 > 无。实时态压过未读态。
    /// 未读判定：outcome 非空且 `updatedAt > viewedAt`（严格大于，B9）。
    static func resolve(live: LiveStatus, outcome: Outcome?,
                        updatedAt: Double, viewedAt: Double) -> ThreadBadge {
        switch live {
        case .running: return .running
        case .waiting: return .waiting
        case .none: break
        }
        let isUnread = (outcome != nil) && (updatedAt > viewedAt)
        guard isUnread, let outcome else { return .none }
        switch outcome {
        case .failed: return .unreadFailed
        case .completed: return .unreadCompleted
        }
    }
}
