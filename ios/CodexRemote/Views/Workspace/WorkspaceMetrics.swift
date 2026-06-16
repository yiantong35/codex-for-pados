import CoreGraphics

/// 五窗口面板的尺寸常量与 clamp 纯函数（design D3/D4/D5）。
enum WorkspaceMetrics {
    /// 右边栏最小 / 理想 / 最大宽（供 `.inspectorColumnWidth`，系统检视列托管 resize）。
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
