import CoreGraphics

/// 五窗口面板的尺寸常量与 clamp 纯函数（design D3/D4/D5）。
enum WorkspaceMetrics {
    /// 右边栏最小 / 理想 / 最大宽（自绘可拖列）。
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

    /// 右栏自绘拖动：把手在右栏左缘，向左拖（dragX<0）增宽、向右拖减宽，
    /// 结果夹到 [rightPanelMinWidth, rightPanelMaxWidth]。
    /// （取代 `.inspector` 内建 resize——后者在三栏全开时不可靠。）
    static func resizedRightWidth(current: CGFloat, dragX: CGFloat) -> CGFloat {
        clamp(current - dragX, min: rightPanelMinWidth, max: rightPanelMaxWidth)
    }
}
