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
            Text("无选中会话，暂无可浏览目录").font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var toolbar: some View {
        HStack {
            Text("文件").font(.subheadline).fontWeight(.semibold)
            Spacer()
            Button { Task { await store.refresh() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .accessibilityLabel(Text("刷新"))
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var contentArea: some View {
        ScrollView {
            if store.isOpeningFile {
                // 文件打开中：预览区显示加载指示，避免停留在上一个文件或空白（设计文档 D）。
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.vertical, 24)
            } else {
                switch store.selectedFile?.content {
                case .text(let s):
                    Text(s)
                        .font(.system(.caption2, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                case .tooLarge:
                    placeholder("文件过大，不支持预览")
                case .binary:
                    placeholder("二进制文件，不支持预览")
                case nil:
                    placeholder("选择文件查看")
                }
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, 24)
    }
}
