import SwiftUI

/// 右栏审查面板：文件树 + 选中文件逐行红绿 diff，按宽度自适应横竖布局。纯查看器。
struct ReviewPanelView: View {
    let source: ReviewDiffSource
    @State private var selectedPath: String?
    private static let threshold: CGFloat = 520

    private var files: [DiffFile] { source.files }
    private var selected: DiffFile? { files.first { $0.path == selectedPath } ?? files.first }

    var body: some View {
        Group {
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
        .onAppear { reconcileSelection() }
        .onChange(of: files.map(\.path)) { _, _ in reconcileSelection() }
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
                if f.kind == .binary {
                    ContentUnavailableView {
                        Label("review.binaryChange", systemImage: "doc.zipper")
                    } description: {
                        Text(f.path).font(.caption.monospaced())
                    }
                    .frame(maxWidth: .infinity, minHeight: 180)
                } else {
                ScrollView(.horizontal, showsIndicators: true) {   // #8b：横滚只包正文区
                    LazyVStack(alignment: .leading, spacing: 0) {
                        // Parser 已携带真实 old/new 行号；双 gutter 便于准确引用 diff。
                        let rows = Array(f.hunks.flatMap { $0.lines }.enumerated())
                        ForEach(rows, id: \.offset) { _, line in
                            diffLineRow(line)
                        }
                        if source.isTruncated {
                            Label("review.diffTruncatedUnknown \(rows.count)", systemImage: "scissors")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(8)
                            FullTextAccessButton(
                                text: source.diff,
                                title: "review.fullContentTitle"
                            )
                            .padding(.horizontal, 8)
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)  // #8b：不折行，随内容变宽
                }
                }
            }
        }
    }

    private func reconcileSelection() {
        selectedPath = Self.resolvedSelection(current: selectedPath, paths: files.map(\.path))
    }

    static func resolvedSelection(current: String?, paths: [String]) -> String? {
        guard !paths.isEmpty else { return nil }
        return current.flatMap { paths.contains($0) ? $0 : nil } ?? paths[0]
    }

    static func fullText(for file: DiffFile) -> String {
        file.rawDiff
    }

    private func diffLineRow(_ line: DiffLine) -> some View {
        let (bg, prefix): (Color, String) = {
            switch line.kind {
            case .add: return (.green.opacity(0.18), "+")
            case .del: return (.red.opacity(0.18), "-")
            case .context: return (.clear, " ")
            }
        }()
        return HStack(alignment: .top, spacing: 0) {
            lineNumber(line.oldLineNo)
            lineNumber(line.newLineNo)
            Text(prefix + line.text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineSpacing(2)
                .padding(.leading, 6)
        }
        .padding(.vertical, 1)
        .background(bg)
    }

    private func lineNumber(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(width: 38, alignment: .trailing)
            .padding(.trailing, 5)
            .background(Color.secondary.opacity(0.06))
    }

    private static func icon(_ k: DiffFileKind) -> String {
        switch k { case .add: "plus.circle"; case .delete: "minus.circle"; case .rename: "arrow.right.circle"; case .binary: "doc"; case .modify: "pencil.circle" }
    }
}
