import SwiftUI

/// 左栏会话行状态圆点（纯展示，设计 D6）。
/// 颜色：运行=橙脉冲 / 待处理=蓝 / 未读失败=红 / 未读完成=绿 / none=不渲染。
struct BadgeDot: View {
    let badge: ThreadBadge
    @State private var pulse = false

    var body: some View {
        if let color = fillColor {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .opacity(badge == .running && pulse ? 0.35 : 1.0)
                .animation(badge == .running
                           ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                           : .default,
                           value: pulse)
                .onAppear { if badge == .running { pulse = true } }
                .accessibilityLabel(Text(a11yKey))
        }
        // .none → 不渲染任何视图
    }

    private var fillColor: Color? {
        switch badge {
        case .none:             return nil
        case .running:          return .orange
        case .waiting:          return .blue
        case .unreadFailed:     return .red
        case .unreadCompleted:  return .green
        }
    }

    private var a11yKey: LocalizedStringKey {
        switch badge {
        case .none:             return ""
        case .running:          return "badge.running"
        case .waiting:          return "badge.waiting"
        case .unreadFailed:     return "badge.unreadFailed"
        case .unreadCompleted:  return "badge.unreadCompleted"
        }
    }
}
