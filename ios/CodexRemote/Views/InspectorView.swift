import SwiftUI

/// 右栏 inspector（v1 简态）：选中线程的环境信息（cwd / 分支 / 模型）。
struct InspectorView: View {
    let thread: ThreadSummary?
    var body: some View {
        if let t = thread {
            List {
                Section("inspector.environment") {
                    row("inspector.cwd", t.cwd)
                    if let b = t.gitInfo?.branch { row("inspector.branch", b) }
                    row("inspector.model", t.modelProvider)
                }
            }
        } else {
            ContentUnavailableView("inspector.empty", systemImage: "sidebar.right")
        }
    }
    @ViewBuilder private func row(_ key: LocalizedStringKey, _ value: String) -> some View {
        HStack { Text(key).foregroundStyle(.secondary); Spacer(); Text(value).lineLimit(1) }
    }
}
