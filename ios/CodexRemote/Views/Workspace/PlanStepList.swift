import SwiftUI

/// 共享的 plan 步骤列表：进度卡片展开 overlay 与 SummaryPopoverView 复用。
/// ✓ 完成(灰) / ◌ 进行中(spinner 弧, 亮白) / ○ 待办(灰)，文案自动换行。
struct PlanStepList: View {
    let steps: [TurnPlanStep]

    var body: some View {
        ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
            Label {
                Text(step.step)
                    .foregroundStyle(step.status == .inProgress ? .primary : .secondary)
            } icon: {
                Image(systemName: Self.icon(for: step.status))
                    .foregroundStyle(step.status == .inProgress ? Color.accentColor : .secondary)
            }
        }
    }

    static func icon(for status: TurnPlanStepStatus) -> String {
        switch status {
        case .completed: return "checkmark.circle.fill"
        case .inProgress: return "circle.dashed"
        case .pending: return "circle"
        }
    }
}
