import CoreGraphics

/// 五窗口面板的尺寸常量与 clamp 纯函数（design D3/D4/D5）。
enum WorkspaceMetrics {
    /// 右边栏最小 / 理想 / 最大宽（原供已移除的系统 `.inspectorColumnWidth`；现由自绘右列复用为 rightColumn 宽度约束，见下）。
    static let rightPanelMinWidth: CGFloat = 220
    static let rightPanelIdealWidth: CGFloat = 320
    static let rightPanelMaxWidth: CGFloat = 480

    /// 下边栏最小 / 理想高（自绘纵向拖 + clamp）。
    static let bottomPanelMinHeight: CGFloat = 140
    static let bottomPanelIdealHeight: CGFloat = 220

    /// 系统列 resize 装饰把手：左右两侧使用同一套尺寸和坐标，避免挂在不同子树时中心线漂移。
    static let resizeHandleEdgePadding: CGFloat = 4
    static let columnResizeHandleInactiveWidth: CGFloat = 3
    static let columnResizeHandleActiveWidth: CGFloat = 5
    static let columnResizeHandleHeight: CGFloat = 44
    static let columnResizeHandleEdgePadding: CGFloat = resizeHandleEdgePadding
    static let bottomResizeHandleTopPadding: CGFloat = resizeHandleEdgePadding
    static let bottomResizeHandleTrackHeight: CGFloat = 16
    static let bottomResizeHandleWidth: CGFloat = 40
    static let bottomResizeHandleInactiveHeight: CGFloat = 4
    static let bottomResizeHandleActiveHeight: CGFloat = 5

    /// 把值夹到 [min, max]，供下栏拖动改高时防止越界。
    static func clamp(_ value: CGFloat, min lo: CGFloat, max hi: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, lo), hi)
    }

    // MARK: - 自绘可调宽三栏（custom-resizable-columns，D2/D4/D8）

    /// 左 / 右 / 中栏最小可用宽（中栏永不被压没）。
    static let leftColumnMinWidth: CGFloat = 240
    static let rightColumnMinWidth: CGFloat = rightPanelMinWidth   // 复用既有 220
    static let centerColumnMinWidth: CGFloat = 320

    /// 左 / 右栏默认宽（无持久化记录时的冷启动初值）。
    static let leftColumnDefaultWidth: CGFloat = 300
    static let rightColumnDefaultWidth: CGFloat = rightPanelIdealWidth   // 复用既有 320

    /// 分隔线命中区宽（手感关键：够宽才好抓；也是视觉线所在的透明命中带宽）。
    static let resizableDividerHitWidth: CGFloat = 14

    /// VoiceOver `accessibilityAdjustableAction` 每次增减的列宽步长（D8）。
    static let columnResizeAccessibilityStep: CGFloat = 40

    /// 单栏最大宽 = 容器总宽的 2/3（随总宽动态，SHALL NOT 固定像素）。
    static func maxColumnWidth(total: CGFloat) -> CGFloat {
        total * 2.0 / 3.0
    }

    /// 把某一栏的建议宽夹到合法区间（D4 三约束）：
    /// 下界 = columnMin；上界 = min(总宽2/3, 总宽 − 另一栏当前宽 − 可见分隔线 − 中栏最小宽)。
    /// 只减「另一栏当前宽」→ 拖一侧只吃中栏余量、不动另一栏（左右解耦）。
    /// 上界可能算出 < columnMin（空间不足），此时用 max(columnMin, upper) 兜底，绝不返回低于 columnMin。
    /// `dividerCount` 为当前实际渲染的分隔线条数（左右各 1，隐藏则不计）；默认 2 = 左右都显示。
    static func clampColumnWidth(_ proposed: CGFloat,
                                 total: CGFloat,
                                 otherColumnWidth: CGFloat,
                                 columnMin: CGFloat,
                                 dividerCount: Int = 2) -> CGFloat {
        let byTwoThirds = maxColumnWidth(total: total)
        let byCenter = total - otherColumnWidth
            - resizableDividerHitWidth * CGFloat(dividerCount)
            - centerColumnMinWidth
        let upper = Swift.min(byTwoThirds, byCenter)
        return clamp(proposed, min: columnMin, max: Swift.max(columnMin, upper))
    }

    /// 中栏渲染宽 = 剩余空间（扣可见分隔线），并保证不低于中栏最小宽。
    /// `dividerCount` 为当前实际渲染的分隔线条数（左右各 1，隐藏则不计）；默认 2 = 左右都显示。
    static func centerColumnWidth(total: CGFloat, left: CGFloat, right: CGFloat,
                                  dividerCount: Int = 2) -> CGFloat {
        Swift.max(centerColumnMinWidth,
                  total - left - right - resizableDividerHitWidth * CGFloat(dividerCount))
    }

    static func columnResizeHandleCenterY(in containerHeight: CGFloat,
                                          pinnedCenterY: CGFloat? = nil) -> CGFloat {
        pinnedCenterY ?? containerHeight / 2
    }

    static func leftColumnResizeHandleCenterX(dividerX: CGFloat,
                                              handleWidth: CGFloat = columnResizeHandleInactiveWidth) -> CGFloat {
        dividerX - columnResizeHandleEdgePadding - handleWidth / 2
    }

    static func rightColumnResizeHandleCenterX(dividerX: CGFloat,
                                               handleWidth: CGFloat = columnResizeHandleInactiveWidth) -> CGFloat {
        dividerX + columnResizeHandleEdgePadding + handleWidth / 2
    }
}
