import SwiftUI
import UIKit

/// 自绘三栏容器（custom-resizable-columns，方案 A）：HStack 左｜分隔线｜中｜分隔线｜右，
/// 替换 NavigationSplitView + .inspector。列宽由 @Binding 驱动 .frame(width:)，
/// 绑定保存用户首选值，实际 frame 宽度按当前容器纯计算派生，窗口自适应不会回写首选值。
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
    /// 一次拖拽 / 一次无障碍调节结束后回调（Task 4 接持久化 save）。
    let onResizeEnded: () -> Void
    /// 紧凑窗口覆盖层的统一关闭入口；调用方同步更新面板意图状态。
    let onDismissOverlay: (WorkspaceMetrics.RequestedSide) -> Void

    @ViewBuilder let left: () -> Left
    @ViewBuilder let center: () -> Center
    @ViewBuilder let right: () -> Right

    // 拖动锚点（D2）：记手势起点在固定坐标系里的绝对 x + 起始列宽，
    // 之后用「当前绝对 x − 起点绝对 x」算增量，不用会自我干扰的 translation。
    @State private var dragStartX: CGFloat?
    @State private var dragStartWidth: CGFloat?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale
    @AccessibilityFocusState private var overlayCloseFocused: Bool
    @FocusState private var focusedDivider: DividerSide?
    @State private var hoveredDivider: DividerSide?
    @State private var draggingDivider: DividerSide?

    private enum DividerSide: Hashable { case left, right }

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
            // 实际渲染的分隔线条数：左右各条件渲染，隐藏则不占宽（消除单栏布局的尾部空隙）。
            let dividerCount = (effLeftVisible ? 1 : 0) + (effRightVisible ? 1 : 0)
            let effectiveWidths = WorkspaceMetrics.effectiveColumnWidths(
                total: total,
                preferredLeft: leftWidth,
                preferredRight: rightWidth,
                showLeft: effLeftVisible,
                showRight: effRightVisible,
                dividerCount: dividerCount)
            let dispLeft = effectiveWidths.left
            let dispRight = effectiveWidths.right
            let centerWidth = WorkspaceMetrics.centerColumnWidth(
                total: total, left: dispLeft, right: dispRight,
                dividerCount: dividerCount)

            ZStack {
                HStack(spacing: 0) {
                    if effLeftVisible {
                        left()
                            .frame(width: dispLeft)
                            .clipped()
                        leftDivider(total: total, dividerCount: dividerCount,
                                    displayedWidth: dispLeft, otherColumnWidth: dispRight)
                    }

                    center()
                        .frame(width: centerWidth)
                        .frame(maxHeight: .infinity)

                    if effRightVisible {
                        rightDivider(total: total, dividerCount: dividerCount,
                                     displayedWidth: dispRight, otherColumnWidth: dispLeft)
                        right()
                            .frame(width: dispRight)
                            .clipped()
                    }
                }
                .frame(width: total, alignment: .leading)
                .allowsHitTesting(overlaySide == .none)
                .accessibilityHidden(overlaySide != .none)

                if overlaySide != .none {
                    Color.black.opacity(0.28)
                        .contentShape(Rectangle())
                        .onTapGesture { dismissOverlay(overlaySide) }
                        .accessibilityHidden(true)
                        .transition(.opacity)
                        .zIndex(1)

                    overlayPanel(side: overlaySide, total: total)
                        .transition(.move(edge: overlaySide == .left ? .leading : .trailing)
                            .combined(with: .opacity))
                        .zIndex(2)
                }
            }
            .frame(width: total, alignment: .leading)
            // 固定坐标系锚在不动的容器上：分隔线 DragGesture 在此系读绝对 x，消除慢拖抖动（D2）。
            .coordinateSpace(name: Self.coordinateSpaceName)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: effLeftVisible)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: effRightVisible)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: overlaySide)
            .onChange(of: overlaySide, initial: true) { _, side in
                overlayCloseFocused = side != .none
            }
        }
    }

    private func overlayPanel(side: WorkspaceMetrics.RequestedSide, total: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button { dismissOverlay(side) } label: {
                    Image(systemName: "xmark")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel(Text("workspace.overlay.close"))
                .accessibilityFocused($overlayCloseFocused)
            }
            .frame(height: 44)
            .padding(.horizontal, 4)
            Divider()

            if side == .left { left() } else { right() }
        }
        .frame(width: overlayWidth(for: side, total: total))
        .frame(maxHeight: .infinity)
        .background(Color(.systemBackground))
        .shadow(color: .black.opacity(0.22), radius: 16,
                x: side == .left ? 6 : -6)
        .frame(maxWidth: .infinity,
               alignment: side == .left ? .leading : .trailing)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    private func overlayWidth(for side: WorkspaceMetrics.RequestedSide, total: CGFloat) -> CGFloat {
        switch side {
        case .left: return WorkspaceMetrics.leftOverlayWidth(total: total, preferred: leftWidth)
        case .right: return WorkspaceMetrics.rightOverlayWidth(total: total, preferred: rightWidth)
        case .none: return 0
        }
    }

    private func dismissOverlay(_ side: WorkspaceMetrics.RequestedSide) {
        overlayCloseFocused = false
        onDismissOverlay(side)
    }

    // MARK: - 左分隔线（只改 leftWidth，右栏不受影响 → 解耦）

    private func leftDivider(total: CGFloat, dividerCount: Int,
                             displayedWidth: CGFloat, otherColumnWidth: CGFloat) -> some View {
        divider(side: .left,
                accessibilityLabel: L10n.string("workspace.column.left.resize", locale: locale),
                accessibilityValue: formattedWidth(displayedWidth)) { absX in
            if dragStartX == nil { dragStartX = absX; dragStartWidth = displayedWidth }
            let dx = absX - (dragStartX ?? absX)
            let base = dragStartWidth ?? displayedWidth
            leftWidth = WorkspaceMetrics.clampColumnWidth(
                base + dx, total: total, otherColumnWidth: otherColumnWidth,
                columnMin: WorkspaceMetrics.leftColumnMinWidth, dividerCount: dividerCount)
        } onAdjust: { direction in
            let delta = direction == .increment
                ? WorkspaceMetrics.columnResizeAccessibilityStep
                : -WorkspaceMetrics.columnResizeAccessibilityStep
            leftWidth = WorkspaceMetrics.clampColumnWidth(
                displayedWidth + delta, total: total, otherColumnWidth: otherColumnWidth,
                columnMin: WorkspaceMetrics.leftColumnMinWidth, dividerCount: dividerCount)
            onResizeEnded()
        }
    }

    // MARK: - 右分隔线（只改 rightWidth，左栏不受影响 → 解耦）
    // 拖右分隔线向左（absX 减小）→ 右栏变宽，故用「起点绝对宽 − dx」。

    private func rightDivider(total: CGFloat, dividerCount: Int,
                              displayedWidth: CGFloat, otherColumnWidth: CGFloat) -> some View {
        divider(side: .right,
                accessibilityLabel: L10n.string("workspace.column.right.resize", locale: locale),
                accessibilityValue: formattedWidth(displayedWidth)) { absX in
            if dragStartX == nil { dragStartX = absX; dragStartWidth = displayedWidth }
            let dx = absX - (dragStartX ?? absX)
            let base = dragStartWidth ?? displayedWidth
            rightWidth = WorkspaceMetrics.clampColumnWidth(
                base - dx, total: total, otherColumnWidth: otherColumnWidth,
                columnMin: WorkspaceMetrics.rightColumnMinWidth, dividerCount: dividerCount)
        } onAdjust: { direction in
            let delta = direction == .increment
                ? WorkspaceMetrics.columnResizeAccessibilityStep
                : -WorkspaceMetrics.columnResizeAccessibilityStep
            rightWidth = WorkspaceMetrics.clampColumnWidth(
                displayedWidth + delta, total: total, otherColumnWidth: otherColumnWidth,
                columnMin: WorkspaceMetrics.rightColumnMinWidth, dividerCount: dividerCount)
            onResizeEnded()
        }
    }

    // MARK: - 分隔线（自绘细线 + 透明命中区，D2/D8）

    /// onDrag 回传固定坐标系里的绝对 x；调用方用起点锚差分算增量。
    /// onAdjust 承接 VoiceOver 增 / 减宽（D8）。
    private func divider(side: DividerSide,
                         accessibilityLabel: String,
                         accessibilityValue: String,
                         onDrag: @escaping (CGFloat) -> Void,
                         onAdjust: @escaping (AccessibilityAdjustmentDirection) -> Void) -> some View {
        let active = hoveredDivider == side || focusedDivider == side || draggingDivider == side
        return Rectangle()
        .fill(Color(uiColor: .separator))
        .frame(width: active ? 2 : 1)
        .frame(width: WorkspaceMetrics.resizableDividerLayoutWidth)
        .frame(maxHeight: .infinity)
        .overlay {
            ZStack {
                Color.clear
                if active {
                    Rectangle().fill(Color.accentColor).frame(width: 2)
                }
            }
            .frame(width: WorkspaceMetrics.resizableDividerHitWidth)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .hoverEffect(.highlight)
            .onHover { hoveredDivider = $0 ? side : nil }
            .focusable()
            .focused($focusedDivider, equals: side)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.coordinateSpaceName))
                    .onChanged { v in
                        draggingDivider = side
                        onDrag(v.location.x)
                    }
                    .onEnded { _ in
                        draggingDivider = nil
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
    }

    private func formattedWidth(_ width: CGFloat) -> String {
        String(format: L10n.string("workspace.column.width %lld", locale: locale),
               locale: locale, Int64(width))
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
