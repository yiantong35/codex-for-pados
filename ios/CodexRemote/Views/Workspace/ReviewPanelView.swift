import SwiftUI

/// 右栏审查面板：文件树 + 选中文件逐行红绿 diff，按宽度自适应横竖布局。纯查看器。
struct ReviewPanelView: View {
    let source: ReviewDiffSource
    @State private var selectedPath: String?
    private static let threshold: CGFloat = 520

    private var files: [DiffFile] { source.files }
    private var selected: DiffFile? { files.first { $0.path == selectedPath } ?? files.first }

    var body: some View {
        if source.isEmpty {
            PanelEmptyState()
        } else {
            GeometryReader { geo in
                if geo.size.width >= Self.threshold {
                    HStack(spacing: 0) { diffArea; Divider(); fileTree.frame(width: 200) }
                } else {
                    VStack(spacing: 0) { fileTree.frame(maxHeight: 180); Divider(); diffArea }
                }
            }
        }
    }

    private var fileTree: some View {
        List(files, selection: $selectedPath) { f in
            Label(f.path, systemImage: Self.icon(f.kind)).font(.caption).lineLimit(1).truncationMode(.middle).tag(f.path)
        }
        .listStyle(.plain)
    }

    private var diffArea: some View {
        ScrollView {                                   // 外层纵向（不变）
            if let f = selected {
                ScrollView(.horizontal, showsIndicators: true) {   // #8b：横滚只包正文区
                    VStack(alignment: .leading, spacing: 0) {
                        // 逐 hunk 展平行，计算 1-based 行号（无文件行号则用序号）。
                        let rows = Array(f.hunks.flatMap { $0.lines }.enumerated())
                        ForEach(rows, id: \.offset) { idx, line in
                            diffLineRow(line, lineNumber: idx + 1)
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)  // #8b：不折行，随内容变宽
                }
            }
        }
    }

    private func diffLineRow(_ line: DiffLine, lineNumber: Int) -> some View {
        let (bg, prefix): (Color, String) = {
            switch line.kind {
            case .add: return (.green.opacity(0.18), "+")
            case .del: return (.red.opacity(0.18), "-")
            case .context: return (.clear, " ")
            }
        }()
        return HStack(alignment: .top, spacing: 6) {
            // #8a：定宽 monospace 行号 gutter。
            Text("\(lineNumber)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
            Text(prefix + line.text)
                .font(.system(.caption, design: .monospaced))   // #8d：caption2 → caption
                .textSelection(.enabled)                          // #8c：可选可复制
                .lineSpacing(2)                                   // #8d：行高
        }
        .padding(.horizontal, 6).padding(.vertical, 1)
        .background(bg)
    }

    private static func icon(_ k: DiffFileKind) -> String {
        switch k { case .add: "plus.circle"; case .delete: "minus.circle"; case .rename: "arrow.right.circle"; case .binary: "doc"; case .modify: "pencil.circle" }
    }
}
