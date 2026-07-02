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
        ScrollView {
            if let f = selected {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(f.hunks.enumerated()), id: \.offset) { _, hunk in
                        ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                            diffLineRow(line)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func diffLineRow(_ line: DiffLine) -> some View {
        let (bg, prefix): (Color, String) = {
            switch line.kind {
            case .add: return (.green.opacity(0.18), "+")
            case .del: return (.red.opacity(0.18), "-")
            case .context: return (.clear, " ")
            }
        }()
        return Text(prefix + line.text)
            .font(.system(.caption2, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(bg)
    }

    private static func icon(_ k: DiffFileKind) -> String {
        switch k { case .add: "plus.circle"; case .delete: "minus.circle"; case .rename: "arrow.right.circle"; case .binary: "doc"; case .modify: "pencil.circle" }
    }
}
