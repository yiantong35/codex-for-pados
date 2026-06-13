import CoreGraphics

/// 五窗口面板的尺寸常量与 clamp 纯函数（design D3/D4/D5）。
enum WorkspaceMetrics {
    /// 右边栏（inspector）最小 / 理想 / 最大宽。
    static let rightPanelMinWidth: CGFloat = 220
    static let rightPanelIdealWidth: CGFloat = 320
    static let rightPanelMaxWidth: CGFloat = 480

    /// 下边栏最小 / 理想高。
    static let bottomPanelMinHeight: CGFloat = 140
    static let bottomPanelIdealHeight: CGFloat = 220

    /// 把值夹到 [min, max]，供拖动改尺寸时防止越界。
    static func clamp(_ value: CGFloat, min lo: CGFloat, max hi: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, lo), hi)
    }
}
