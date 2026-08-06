import SwiftUI

/// 文件浏览 tab（只读）：懒加载目录树 + 文件内容查看 + 手动刷新。消费 FileBrowserStore。
/// 无写入能力（写文件走 agent 对话）。布局自适应见 Task 10。
struct FileBrowserView: View {
    let store: FileBrowserStore

    private static let threshold: CGFloat = 520

    var body: some View {
        if store.isEmpty {
            emptyState
        } else {
            VStack(spacing: 0) {
                toolbar
                Divider()
                GeometryReader { geo in
                    if geo.size.width >= Self.threshold {
                        HStack(spacing: 0) {
                            directoryTree.frame(width: 220)
                            Divider()
                            contentArea
                        }
                    } else {
                        VStack(spacing: 0) {
                            directoryTree.frame(maxHeight: 220)
                            Divider()
                            contentArea
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder").font(.largeTitle).foregroundStyle(.secondary)
            Text("fileBrowser.empty").font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var toolbar: some View {
        HStack {
            Text("fileBrowser.title").font(.subheadline).fontWeight(.semibold)
            Spacer()
            Button { Task { await store.refresh() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .accessibilityLabel(Text("fileBrowser.refresh"))
            .minimumHitTarget44()
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    // 递归目录树：从根路径起，按缓存的展开态缩进渲染。
    @ViewBuilder private var directoryTree: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let root = store.rootPath {
                    treeLevel(path: root, depth: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // 渲染 path 目录下的一层 entries（若已加载且展开）。
    // 递归调用自身，用 AnyView 打破 opaque return type 的自引用循环。
    private func treeLevel(path: String, depth: Int) -> AnyView {
        let node = store.nodes[path]
        return AnyView(
            VStack(alignment: .leading, spacing: 0) {
                if node?.isLoading == true {
                    ProgressView().padding(.leading, CGFloat(depth) * 14 + 10)
                } else if let err = node?.error {
                    Text(err).font(.caption).foregroundStyle(.red).padding(.leading, CGFloat(depth) * 14 + 10)
                }
                if let entries = node?.entries, node?.isExpanded == true {
                    ForEach(entries, id: \.fileName) { entry in
                        let childPath = path + "/" + entry.fileName
                        row(entry: entry, path: childPath, depth: depth)
                        if entry.isDirectory {
                            treeLevel(path: childPath, depth: depth + 1)
                        }
                    }
                }
            }
        )
    }

    private func row(entry: FsReadDirectoryEntry, path: String, depth: Int) -> some View {
        Button {
            Task {
                if entry.isDirectory { await store.toggleExpand(path) }
                else { await store.openFile(path) }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: entry.isDirectory ? "folder" : "doc.text")
                    .foregroundStyle(entry.isDirectory ? Color.accentColor : Color.secondary)
                Text(entry.fileName).font(.callout).lineLimit(1).truncationMode(.middle)
                Spacer()
            }
            .padding(.leading, CGFloat(depth) * 14 + 10)
            .padding(.vertical, 3)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var contentArea: some View {
        ScrollView {                                   // 外层纵向（不变）
            if case .loading = store.fileOpenState {
                // 文件打开中：预览区显示加载指示，避免停留在上一个文件或空白（设计文档 D）。
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.vertical, 24)
            } else {
                switch store.fileOpenState {
                case .loaded(let file):
                    switch file.content {
                case .text(let s):
                    fileTextBody(s)
                case .tooLarge:
                    placeholder("fileBrowser.tooLarge")
                case .binary:
                    placeholder("fileBrowser.binary")
                    }
                case .failed(let path):
                    VStack(spacing: 10) {
                        Label("fileBrowser.loadFileFailed", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                        Button("fileBrowser.retry") { Task { await store.openFile(path) } }
                            .buttonStyle(.borderedProminent)
                            .minimumHitTarget44()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.vertical, 24)
                case .idle, .loading:
                    placeholder("fileBrowser.selectFile")
                }
            }
        }
    }

    /// #8：文件正文——1-based 行号 gutter + 长行横滚不折行 + 可选 + 略大字号/行高。
    private func fileTextBody(_ s: String) -> some View {
        ScrollView(.horizontal, showsIndicators: true) {       // #8b：横滚只包正文区
            VStack(alignment: .leading, spacing: 0) {
                let lines = Array(s.split(separator: "\n", omittingEmptySubsequences: false).enumerated())
                ForEach(lines, id: \.offset) { idx, line in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(idx + 1)")                     // #8a：1-based 行号 gutter
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                        Text(String(line).isEmpty ? " " : String(line))
                            .font(.system(.caption, design: .monospaced))   // #8d：caption2 → caption
                            .textSelection(.enabled)                        // #8c：可选可复制
                            .lineSpacing(2)                                  // #8d：行高
                    }
                }
            }
            .padding(8)
            .fixedSize(horizontal: true, vertical: false)      // #8b：不折行
        }
    }

    private func placeholder(_ key: LocalizedStringKey) -> some View {
        Text(key).font(.callout).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, 24)
    }
}
