import SwiftUI
import Observation

/// 右栏跳转意图（设计 D6）：快捷键请求，一次性信号，RightPanelContainerView 消费即复位。
enum RightPanelIntent: Equatable {
    case review, files, sideChat, toggleFullscreen

    /// tab 跳转意图 → 目标 tab；全屏意图无对应 tab（返回 nil）。
    var targetTab: RightPanelTab? {
        switch self {
        case .review:           return .review
        case .files:            return .files
        case .sideChat:         return .sideChat
        case .toggleFullscreen: return nil
        }
    }
}

/// 工作区面板布局状态（设计 D4，方案 A）：从 RootSplitView 抬升的面板开合态单一数据源，
/// 顶栏按钮与面板快捷键读写同一份。仿现有 ActiveConversationHolder：由 RootSplitView 持为
/// 局部 @State 并注入 detail 环境，抬升范围最小化。
@Observable
@MainActor
final class WorkspaceLayoutStore {
    var leftVisible: Bool
    var showRight: Bool
    var showBottom: Bool
    var showSummary: Bool
    var showSettings: Bool
    /// User-preferred column widths. ResizableColumns derives container-safe effective widths;
    /// only explicit resize interactions update these preferences, which ColumnWidthStore persists.
    var leftWidth: CGFloat
    var rightWidth: CGFloat
    /// 右栏跳转/全屏一次性信号（设计 D6）；消费即复位为 nil，防自触发回环（功耗约束 4）。
    var pendingRightPanelIntent: RightPanelIntent?
    /// #3：最近一次被打开的侧栏——供 ResizableColumns 在窄窗中间档做 tiebreaker。
    var lastRequested: WorkspaceMetrics.RequestedSide = .none
    /// 最近一次工作区容器宽度。面板切换必须依据实际呈现（并排列或紧凑覆盖层），
    /// 不能仅依据用户偏好布尔值，否则宽屏已显示的面板会出现首按无效。
    private(set) var containerWidth: CGFloat = .greatestFiniteMagnitude

    init(leftVisible: Bool = true,
         showRight: Bool = false,
         showBottom: Bool = false,
         showSummary: Bool = false,
         showSettings: Bool = false,
         leftWidth: CGFloat = WorkspaceMetrics.leftColumnDefaultWidth,
         rightWidth: CGFloat = WorkspaceMetrics.rightColumnDefaultWidth) {
        self.leftVisible = leftVisible
        self.showRight = showRight
        self.showBottom = showBottom
        self.showSummary = showSummary
        self.showSettings = showSettings
        self.leftWidth = leftWidth
        self.rightWidth = rightWidth
    }

    /// 快捷键请求右栏跳转/全屏（设计 D6）：先开右栏（未开先开），再发一次性信号。
    func requestRightPanel(_ intent: RightPanelIntent) {
        showRight = true
        lastRequested = .right
        pendingRightPanelIntent = intent
    }

    func updateContainerWidth(_ width: CGFloat) {
        guard width.isFinite, width > 0 else { return }
        containerWidth = width
    }

    func toggleRightPanel() {
        if isPresented(.right) {
            showRight = false
        } else {
            showRight = true
            lastRequested = .right
        }
    }

    func toggleLeftPanel() {
        if isPresented(.left) {
            leftVisible = false
        } else {
            leftVisible = true
            lastRequested = .left
        }
    }

    private func isPresented(_ side: WorkspaceMetrics.RequestedSide) -> Bool {
        let plan = WorkspaceMetrics.columnVisibilityPlan(
            total: containerWidth,
            wantLeft: leftVisible,
            wantRight: showRight,
            lastRequested: lastRequested
        )
        let overlay = WorkspaceMetrics.overlaySide(
            total: containerWidth,
            wantLeft: leftVisible,
            wantRight: showRight,
            plan: plan,
            lastRequested: lastRequested
        )
        switch side {
        case .left: return plan.showLeft || overlay == .left
        case .right: return plan.showRight || overlay == .right
        case .none: return false
        }
    }
}
