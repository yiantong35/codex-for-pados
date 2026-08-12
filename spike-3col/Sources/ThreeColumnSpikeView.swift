import SwiftUI

struct ThreeColumnSpikeView: View {
    static let dragSpace = "dragSpace"
    static let minimumColumnWidth: CGFloat = 120
    static let minimumMiddleWidth: CGFloat = 200
    static let dividerHitWidth: CGFloat = 14

    @State private var leftWidth: CGFloat = 280
    @State private var rightWidth: CGFloat = 320
    @State private var dragStartX: CGFloat?
    @State private var dragStartLeft: CGFloat?
    @State private var dragStartRight: CGFloat?

    var body: some View {
        GeometryReader { proxy in
            let total = proxy.size.width
            let widths = Self.constrainedWidths(total: total, left: leftWidth, right: rightWidth)

            VStack(spacing: 0) {
                header(total: total, widths: widths)
                Divider()
                HStack(spacing: 0) {
                    if widths.left > 0 {
                        ColumnContent(title: "左栏 Left", color: .blue, rowCount: 40)
                            .frame(width: widths.left)

                        divider(
                            onChanged: { absoluteX in
                                if dragStartX == nil {
                                    dragStartX = absoluteX
                                    dragStartLeft = widths.left
                                }
                                leftWidth = (dragStartLeft ?? widths.left) + absoluteX - (dragStartX ?? absoluteX)
                            },
                            onEnded: {
                                leftWidth = widths.left
                                dragStartX = nil
                                dragStartLeft = nil
                            }
                        )
                    }

                    ColumnContent(title: "中栏 Middle(重内容 500 行)", color: .gray, rowCount: 500)
                        .frame(width: widths.middle)

                    if widths.right > 0 {
                        divider(
                            onChanged: { absoluteX in
                                if dragStartX == nil {
                                    dragStartX = absoluteX
                                    dragStartRight = widths.right
                                }
                                rightWidth = (dragStartRight ?? widths.right) - absoluteX + (dragStartX ?? absoluteX)
                            },
                            onEnded: {
                                rightWidth = widths.right
                                dragStartX = nil
                                dragStartRight = nil
                            }
                        )

                        ColumnContent(title: "右栏 Right", color: .green, rowCount: 40)
                            .frame(width: widths.right)
                    }
                }
            }
            .coordinateSpace(name: Self.dragSpace)
            .onChange(of: total, initial: true) {
                leftWidth = widths.left
                rightWidth = widths.right
            }
        }
    }

    static func constrainedWidths(total: CGFloat, left: CGFloat, right: CGFloat)
        -> (left: CGFloat, middle: CGFloat, right: CGFloat) {
        let minimumThreeColumnWidth = minimumColumnWidth * 2 + minimumMiddleWidth + dividerHitWidth * 2
        guard total >= minimumThreeColumnWidth else {
            return (0, max(0, total), 0)
        }
        let available = max(0, total - dividerHitWidth * 2)
        let maxSide = total * 2 / 3
        var resolvedLeft = min(max(left, minimumColumnWidth), maxSide)
        var resolvedRight = min(max(right, minimumColumnWidth), maxSide)
        let maximumSides = max(0, available - minimumMiddleWidth)
        let sideTotal = resolvedLeft + resolvedRight
        if sideTotal > maximumSides, sideTotal > 0 {
            let scale = maximumSides / sideTotal
            resolvedLeft *= scale
            resolvedRight *= scale
        }
        let middle = max(0, available - resolvedLeft - resolvedRight)
        return (resolvedLeft, middle, resolvedRight)
    }

    private func header(total: CGFloat, widths: (left: CGFloat, middle: CGFloat, right: CGFloat)) -> some View {
        HStack(spacing: 12) {
            Text("三栏自绘拖拽 spike").font(.headline)
            Spacer()
            Text(String(format: "总宽 %.0f", total)).font(.caption)
            Text(String(format: "L %.0f", widths.left)).font(.caption.monospaced())
            Text(String(format: "M %.0f", widths.middle)).font(.caption.monospaced())
            Text(String(format: "R %.0f", widths.right)).font(.caption.monospaced())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func divider(onChanged: @escaping (CGFloat) -> Void,
                         onEnded: @escaping () -> Void) -> some View {
        ZStack {
            Color.clear
            Rectangle().fill(Color.secondary.opacity(0.35)).frame(width: 1)
        }
        .frame(width: Self.dividerHitWidth)
        .contentShape(Rectangle())
        .hoverEffect(.highlight)
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.dragSpace))
                .onChanged { onChanged($0.location.x) }
                .onEnded { _ in onEnded() }
        )
    }
}

struct ColumnContent: View {
    let title: String
    let color: Color
    let rowCount: Int

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(color.opacity(0.18))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(0..<rowCount, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(title) · 第 \(index) 行").font(.callout.weight(.medium))
                            Text("这是一段用于撑重量的示例内容，模拟对话消息卡片的文本高度与换行。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.12)))
                    }
                }
                .padding(10)
            }
        }
        .background(color.opacity(0.06))
    }
}
