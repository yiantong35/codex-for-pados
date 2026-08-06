import SwiftUI

/// tab 圆点聚合状态（D10）。优先级：error > attention > running > unread > none。
/// 颜色由 View 层映射：error 红闪 / attention 橙闪 / running 绿常亮 / unread 蓝常亮。
enum TabIndicator: Equatable {
    case none, unread, running, attention, error, disconnected

    // disconnected（灰点，连接异常）非闪烁：与 error/attention（红橙闪）严格正交。
    var isBlinking: Bool { self == .attention || self == .error }

    var accessibilityKey: LocalizedStringKey {
        switch self {
        case .none:         "tab.status.none"
        case .unread:       "tab.status.unread"
        case .running:      "tab.status.running"
        case .attention:    "tab.status.attention"
        case .error:        "tab.status.error"
        case .disconnected: "tab.status.disconnected"
        }
    }

    var symbolName: String? {
        switch self {
        case .none:         nil
        case .unread:       "circle.fill"
        case .running:      "play.fill"
        case .attention:    "exclamationmark"
        case .error:        "xmark"
        case .disconnected: "wifi.slash"
        }
    }

    func shouldAnimate(reduceMotion: Bool) -> Bool {
        isBlinking && !reduceMotion
    }

    /// 聚合一个 Session 内所有会话状态 + 未读，取最高优先级。未连接一律 .none。
    static func resolve(isConnected: Bool, statuses: [ThreadStatus], hasUnread: Bool = false) -> TabIndicator {
        guard isConnected else { return .none }
        if statuses.contains(where: { if case .systemError = $0 { return true }; return false }) { return .error }
        let attention = statuses.contains { status in
            if case .active(let flags) = status {
                return flags.contains(.waitingOnApproval) || flags.contains(.waitingOnUserInput)
            }
            return false
        }
        if attention { return .attention }
        let running = statuses.contains { if case .active = $0 { return true }; return false }
        if running { return .running }
        return hasUnread ? .unread : .none
    }
}
