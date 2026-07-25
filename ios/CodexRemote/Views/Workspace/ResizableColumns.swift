import SwiftUI

/// 自绘三栏容器（custom-resizable-columns，方案 A）：HStack 左｜分隔线｜中｜分隔线｜右，
/// 替换 NavigationSplitView + .inspector。列宽由 @Binding 驱动 .frame(width:)，
/// 拖拽用固定坐标系 + 绝对 location.x 起点锚差分（D2，消除慢拖抖动），
/// 宽度约束全部走 WorkspaceMetrics 纯函数（D4，左右解耦）。
///
/// 性能范式（D3）：外层 GeometryReader 只读恒定「总宽」——拖动期间总宽不变，故不因几何变化
/// 重算子树；列宽变化只改 .frame(width:)。重内容（中栏）由调用方隔离成带稳定 .id 的独立子视图。
struct ResizableColumns<Left: View, Center: View, Right: View>: View {
    static var coordinateSpaceName: String { "cols" }

    @Binding var leftWidth: CGFloat
    @Binding var rightWidth: CGFloat
    /// 左 / 右栏显隐（D5：条件渲染 + 宽度动画，竖屏并排挤窄，无浮层）。
    let leftVisible: Bool
    let rightVisible: Bool
    /// 外部载入列宽的修订号：变化即用当前真实总宽重新收敛已写入的列宽（D7 窄屏恢复兜底）。
    let loadRevision: Int
    /// 一次拖拽 / 一次无障碍调节结束后回调（Task 4 接持久化 save）。
    let onResizeEnded: () -> Void

    @ViewBuilder let left: () -> Left
    @ViewBuilder let center: () -> Center
    @ViewBuilder let right: () -> Right

    // 拖动锚点（D2）：记手势起点在固定坐标系里的绝对 x + 起始列宽，
    // 之后用「当前绝对 x − 起点绝对 x」算增量，不用会自我干扰的 translation。
    @State private var dragStartX: CGFloat?
    @State private var dragStartWidth: CGFloat?

    var body: some View {
        GeometryReader { proxy in
            // 只读恒定总宽做 clamp 边界（D3）——不把 proxy 传进子树逐帧重算。
            let total = proxy.size.width
            // 实际渲染的分隔线条数：左右各条件渲染，隐藏则不占宽（消除单栏布局的尾部空隙）。
            let dividerCount = (leftVisible ? 1 : 0) + (rightVisible ? 1 : 0)
            let centerWidth = WorkspaceMetrics.centerColumnWidth(
                total: total, left: displayedLeft, right: displayedRight,
                dividerCount: dividerCount)

            HStack(spacing: 0) {
                if leftVisible {
                    left()
                        .frame(width: displayedLeft)
                        .clipped()
                    leftDivider(total: total, dividerCount: dividerCount)
                }

                center()
                    .frame(width: centerWidth)
                    .frame(maxHeight: .infinity)

                if rightVisible {
                    rightDivider(total: total, dividerCount: dividerCount)
                    right()
                        .frame(width: displayedRight)
                        .clipped()
                }
            }
            .frame(width: total, alignment: .leading)
            // 旋转 / 分屏使总宽突变时，已存绝对列宽可能越界 → 用新总宽重跑 clamp 收敛（Design 风险表）。
            .onChange(of: total, initial: true) { _, newTotal in reclamp(total: newTotal, dividerCount: dividerCount) }
            // 外部载入列宽（切 tab / 冷启动）后，用当前真实总宽重新收敛已写入的列宽，
            // 不依赖 .task 与首帧 onChange(of: total) 的先后顺序（D7 窄屏恢复溢出兜底）。
            .onChange(of: loadRevision) { _, _ in reclamp(total: total, dividerCount: dividerCount) }
            // 固定坐标系锚在不动的容器上：分隔线 DragGesture 在此系读绝对 x，消除慢拖抖动（D2）。
            .coordinateSpace(name: Self.coordinateSpaceName)
            .animation(.easeOut(duration: 0.22), value: leftVisible)   // D5 宽度动画
            .animation(.easeOut(duration: 0.22), value: rightVisible)
        }
    }

    // 渲染用列宽：隐藏时按 0 参与中栏计算（避免中栏读到过期宽度）。
    private var displayedLeft: CGFloat { leftVisible ? leftWidth : 0 }
    private var displayedRight: CGFloat { rightVisible ? rightWidth : 0 }

    // MARK: - 左分隔线（只改 leftWidth，右栏不受影响 → 解耦）

    private func leftDivider(total: CGFloat, dividerCount: Int) -> some View {
        divider(accessibilityLabel: "workspace.column.left.resize") { absX in
            if dragStartX == nil { dragStartX = absX; dragStartWidth = leftWidth }
            let dx = absX - (dragStartX ?? absX)
            let base = dragStartWidth ?? leftWidth
            leftWidth = WorkspaceMetrics.clampColumnWidth(
                base + dx, total: total, otherColumnWidth: displayedRight,
                columnMin: WorkspaceMetrics.leftColumnMinWidth, dividerCount: dividerCount)
        } onAdjust: { direction in
            let delta = direction == .increment
                ? WorkspaceMetrics.columnResizeAccessibilityStep
                : -WorkspaceMetrics.columnResizeAccessibilityStep
            leftWidth = WorkspaceMetrics.clampColumnWidth(
                leftWidth + delta, total: total, otherColumnWidth: displayedRight,
                columnMin: WorkspaceMetrics.leftColumnMinWidth, dividerCount: dividerCount)
            onResizeEnded()
        }
    }

    // MARK: - 右分隔线（只改 rightWidth，左栏不受影响 → 解耦）
    // 拖右分隔线向左（absX 减小）→ 右栏变宽，故用「起点绝对宽 − dx」。

    private func rightDivider(total: CGFloat, dividerCount: Int) -> some View {
        divider(accessibilityLabel: "workspace.column.right.resize") { absX in
            if dragStartX == nil { dragStartX = absX; dragStartWidth = rightWidth }
            let dx = absX - (dragStartX ?? absX)
            let base = dragStartWidth ?? rightWidth
            rightWidth = WorkspaceMetrics.clampColumnWidth(
                base - dx, total: total, otherColumnWidth: displayedLeft,
                columnMin: WorkspaceMetrics.rightColumnMinWidth, dividerCount: dividerCount)
        } onAdjust: { direction in
            let delta = direction == .increment
                ? WorkspaceMetrics.columnResizeAccessibilityStep
                : -WorkspaceMetrics.columnResizeAccessibilityStep
            rightWidth = WorkspaceMetrics.clampColumnWidth(
                rightWidth + delta, total: total, otherColumnWidth: displayedLeft,
                columnMin: WorkspaceMetrics.rightColumnMinWidth, dividerCount: dividerCount)
            onResizeEnded()
        }
    }

    // MARK: - 分隔线（自绘细线 + 透明命中区，D2/D8）

    /// onDrag 回传固定坐标系里的绝对 x；调用方用起点锚差分算增量。
    /// onAdjust 承接 VoiceOver 增 / 减宽（D8）。
    private func divider(accessibilityLabel: LocalizedStringKey,
                         onDrag: @escaping (CGFloat) -> Void,
                         onAdjust: @escaping (AccessibilityAdjustmentDirection) -> Void) -> some View {
        ZStack {
            Color.clear                                             // 透明命中带（把手可隐藏，仍可拖 → spec）
            Rectangle().fill(Color.secondary.opacity(0.35)).frame(width: 1)
        }
        .frame(width: WorkspaceMetrics.resizableDividerHitWidth)    // 命中区 ≥ 视觉线（D8）
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .hoverEffect(.highlight)
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.coordinateSpaceName))
                .onChanged { v in onDrag(v.location.x) }
                .onEnded { _ in
                    dragStartX = nil
                    dragStartWidth = nil
                    onResizeEnded()
                }
        )
        .accessibilityElement()
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityAddTraits(.allowsDirectInteraction)
        .accessibilityAdjustableAction(onAdjust)
    }

    // 总宽突变后，把左右列宽在新总宽下重新收敛（不直接用旧绝对值）。
    private func reclamp(total: CGFloat, dividerCount: Int) {
        leftWidth = WorkspaceMetrics.clampColumnWidth(
            leftWidth, total: total, otherColumnWidth: displayedRight,
            columnMin: WorkspaceMetrics.leftColumnMinWidth, dividerCount: dividerCount)
        rightWidth = WorkspaceMetrics.clampColumnWidth(
            rightWidth, total: total, otherColumnWidth: displayedLeft,
            columnMin: WorkspaceMetrics.rightColumnMinWidth, dividerCount: dividerCount)
    }
}
