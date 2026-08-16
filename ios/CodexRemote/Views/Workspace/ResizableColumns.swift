import SwiftUI
import UIKit

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
    /// #3：窄窗中间档 tiebreaker（哪侧是用户最后请求）。
    let lastRequested: WorkspaceMetrics.RequestedSide
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale

    var body: some View {
        GeometryReader { proxy in
            // 只读恒定总宽做 clamp 边界（D3）——不把 proxy 传进子树逐帧重算。
            let total = proxy.size.width
            // D4：窄窗降级——用户意图（leftVisible/rightVisible）经容器宽过滤成实际显隐，
            // 保证渲染宽度之和 ≤ 容器、中栏永远完整。宽度恢复到阈值以上 plan 即还原用户意图。
            let plan = WorkspaceMetrics.columnVisibilityPlan(
                total: total, wantLeft: leftVisible, wantRight: rightVisible,
                lastRequested: lastRequested)
            let effLeftVisible = plan.showLeft
            let effRightVisible = plan.showRight
            let overlaySide = WorkspaceMetrics.overlaySide(
                total: total, wantLeft: leftVisible, wantRight: rightVisible,
                plan: plan, lastRequested: lastRequested)
            // 渲染用列宽：隐藏（含降级收起）时按 0 参与中栏 / clamp 计算，避免读到过期宽度或把
            // 已收起栏的持久宽度算进 otherColumnWidth。列宽持久化（leftWidth/rightWidth 存值）不受影响。
            let dispLeft: CGFloat = effLeftVisible ? leftWidth : 0
            let dispRight: CGFloat = effRightVisible ? rightWidth : 0
            // 实际渲染的分隔线条数：左右各条件渲染，隐藏则不占宽（消除单栏布局的尾部空隙）。
            let dividerCount = (effLeftVisible ? 1 : 0) + (effRightVisible ? 1 : 0)
            let centerWidth = WorkspaceMetrics.centerColumnWidth(
                total: total, left: dispLeft, right: dispRight,
                dividerCount: dividerCount)

            ZStack {
                HStack(spacing: 0) {
                    if effLeftVisible {
                        left()
                            .frame(width: dispLeft)
                            .clipped()
                        leftDivider(total: total, dividerCount: dividerCount, otherColumnWidth: dispRight)
                    }

                    center()
                        .frame(width: centerWidth)
                        .frame(maxHeight: .infinity)

                    if effRightVisible {
                        rightDivider(total: total, dividerCount: dividerCount, otherColumnWidth: dispLeft)
                        right()
                            .frame(width: dispRight)
                            .clipped()
                    }
                }
                .frame(width: total, alignment: .leading)

                if overlaySide == .left {
                    left()
                        .frame(width: WorkspaceMetrics.leftOverlayWidth(
                            total: total,
                            preferred: leftWidth))
                        .frame(maxHeight: .infinity)
                        .background(Color(.systemBackground))
                        .shadow(color: .black.opacity(0.22), radius: 16, x: 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                        .zIndex(1)
                }

                if overlaySide == .right {
                    right()
                        .frame(width: WorkspaceMetrics.rightOverlayWidth(
                            total: total,
                            preferred: rightWidth))
                        .frame(maxHeight: .infinity)
                        .background(Color(.systemBackground))
                        .shadow(color: .black.opacity(0.22), radius: 16, x: -6)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                        .zIndex(1)
                }
            }
            .frame(width: total, alignment: .leading)
            // 旋转 / 分屏使总宽突变时，已存绝对列宽可能越界 → 用新总宽重跑 clamp 收敛（Design 风险表）。
            .onChange(of: total, initial: true) { _, newTotal in
                reclamp(total: newTotal, dividerCount: dividerCount,
                        dispLeft: dispLeft, dispRight: dispRight,
                        effLeftVisible: effLeftVisible, effRightVisible: effRightVisible)
            }
            // 外部载入列宽（切 tab / 冷启动）后，用当前真实总宽重新收敛已写入的列宽，
            // 不依赖 .task 与首帧 onChange(of: total) 的先后顺序（D7 窄屏恢复溢出兜底）。
            .onChange(of: loadRevision) { _, _ in
                reclamp(total: total, dividerCount: dividerCount,
                        dispLeft: dispLeft, dispRight: dispRight,
                        effLeftVisible: effLeftVisible, effRightVisible: effRightVisible)
            }
            // 切换某一栏显隐会改变可用分隔线数与占宽：立即用新 dividerCount 重夹，
            // 让相邻栏收敛到最小宽而非把对侧栏挤出屏幕（修复「开左栏→右栏出不来/自动收回」）。
            .onChange(of: dividerCount) { _, newCount in
                reclamp(total: total, dividerCount: newCount,
                        dispLeft: dispLeft, dispRight: dispRight,
                        effLeftVisible: effLeftVisible, effRightVisible: effRightVisible)
            }
            // 固定坐标系锚在不动的容器上：分隔线 DragGesture 在此系读绝对 x，消除慢拖抖动（D2）。
            .coordinateSpace(name: Self.coordinateSpaceName)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: effLeftVisible)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: effRightVisible)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: overlaySide)
        }
    }

    // MARK: - 左分隔线（只改 leftWidth，右栏不受影响 → 解耦）

    private func leftDivider(total: CGFloat, dividerCount: Int, otherColumnWidth: CGFloat) -> some View {
        divider(accessibilityLabel: L10n.string("workspace.column.left.resize", locale: locale),
                accessibilityValue: formattedWidth(leftWidth)) { absX in
            if dragStartX == nil { dragStartX = absX; dragStartWidth = leftWidth }
            let dx = absX - (dragStartX ?? absX)
            let base = dragStartWidth ?? leftWidth
            leftWidth = WorkspaceMetrics.clampColumnWidth(
                base + dx, total: total, otherColumnWidth: otherColumnWidth,
                columnMin: WorkspaceMetrics.leftColumnMinWidth, dividerCount: dividerCount)
        } onAdjust: { direction in
            let delta = direction == .increment
                ? WorkspaceMetrics.columnResizeAccessibilityStep
                : -WorkspaceMetrics.columnResizeAccessibilityStep
            leftWidth = WorkspaceMetrics.clampColumnWidth(
                leftWidth + delta, total: total, otherColumnWidth: otherColumnWidth,
                columnMin: WorkspaceMetrics.leftColumnMinWidth, dividerCount: dividerCount)
            onResizeEnded()
        }
    }

    // MARK: - 右分隔线（只改 rightWidth，左栏不受影响 → 解耦）
    // 拖右分隔线向左（absX 减小）→ 右栏变宽，故用「起点绝对宽 − dx」。

    private func rightDivider(total: CGFloat, dividerCount: Int, otherColumnWidth: CGFloat) -> some View {
        divider(accessibilityLabel: L10n.string("workspace.column.right.resize", locale: locale),
                accessibilityValue: formattedWidth(rightWidth)) { absX in
            if dragStartX == nil { dragStartX = absX; dragStartWidth = rightWidth }
            let dx = absX - (dragStartX ?? absX)
            let base = dragStartWidth ?? rightWidth
            rightWidth = WorkspaceMetrics.clampColumnWidth(
                base - dx, total: total, otherColumnWidth: otherColumnWidth,
                columnMin: WorkspaceMetrics.rightColumnMinWidth, dividerCount: dividerCount)
        } onAdjust: { direction in
            let delta = direction == .increment
                ? WorkspaceMetrics.columnResizeAccessibilityStep
                : -WorkspaceMetrics.columnResizeAccessibilityStep
            rightWidth = WorkspaceMetrics.clampColumnWidth(
                rightWidth + delta, total: total, otherColumnWidth: otherColumnWidth,
                columnMin: WorkspaceMetrics.rightColumnMinWidth, dividerCount: dividerCount)
            onResizeEnded()
        }
    }

    // MARK: - 分隔线（自绘细线 + 透明命中区，D2/D8）

    /// onDrag 回传固定坐标系里的绝对 x；调用方用起点锚差分算增量。
    /// onAdjust 承接 VoiceOver 增 / 减宽（D8）。
    private func divider(accessibilityLabel: String,
                         accessibilityValue: String,
                         onDrag: @escaping (CGFloat) -> Void,
                         onAdjust: @escaping (AccessibilityAdjustmentDirection) -> Void) -> some View {
        ZStack {
            Color.clear                                             // 透明命中带（把手可隐藏，仍可拖 → spec）
            // 用主题橙（accentColor，深浅色各自的橙）画分界线，黑底上也醒目。
            Rectangle().fill(Color.accentColor).frame(width: 1)
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
        .background {
            AccessibilityAdjustableElement(
                label: accessibilityLabel,
                value: accessibilityValue,
                onIncrement: { onAdjust(.increment) },
                onDecrement: { onAdjust(.decrement) }
            )
        }
    }

    private func formattedWidth(_ width: CGFloat) -> String {
        String(format: L10n.string("workspace.column.width %lld", locale: locale),
               locale: locale, Int64(width))
    }

    // 总宽突变后，把左右列宽在新总宽下重新收敛（不直接用旧绝对值）。
    // 只对当前实际可见（effXVisible）的栏做 clamp——隐藏（含 D4 降级收起）的栏跳过、绝不写其
    // 持久宽：否则窄窗把已收起栏的 leftWidth/rightWidth 夹到 columnMin，宽度恢复后也回不到
    // 用户上次拖定的值（违反列宽持久化铁律）。dispLeft/dispRight 仍传渲染态（含 0）作对侧边界。
    private func reclamp(total: CGFloat, dividerCount: Int, dispLeft: CGFloat, dispRight: CGFloat,
                          effLeftVisible: Bool, effRightVisible: Bool) {
        if effLeftVisible {
            leftWidth = WorkspaceMetrics.clampColumnWidth(
                leftWidth, total: total, otherColumnWidth: dispRight,
                columnMin: WorkspaceMetrics.leftColumnMinWidth, dividerCount: dividerCount)
        }
        if effRightVisible {
            rightWidth = WorkspaceMetrics.clampColumnWidth(
                rightWidth, total: total, otherColumnWidth: dispLeft,
                columnMin: WorkspaceMetrics.rightColumnMinWidth, dividerCount: dividerCount)
        }
    }
}

/// UIKit supplies a stable textual accessibility value for adjustable controls. SwiftUI's
/// adjustable modifier currently exposes these custom drag handles as sliders with a NaN value.
struct AccessibilityAdjustableElement: UIViewRepresentable {
    let label: String
    let value: String
    let onIncrement: () -> Void
    let onDecrement: () -> Void

    func makeUIView(context: Context) -> AdjustableView {
        AdjustableView()
    }

    func updateUIView(_ view: AdjustableView, context: Context) {
        view.isAccessibilityElement = true
        view.accessibilityTraits = [.adjustable]
        view.accessibilityLabel = label
        view.accessibilityValue = value
        view.onIncrement = onIncrement
        view.onDecrement = onDecrement
        view.backgroundColor = .clear
    }

    final class AdjustableView: UIView {
        var onIncrement: (() -> Void)?
        var onDecrement: (() -> Void)?

        override func accessibilityIncrement() { onIncrement?() }
        override func accessibilityDecrement() { onDecrement?() }
    }
}
