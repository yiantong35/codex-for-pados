import SwiftUI

/// 右边栏（design D3）。本 change：占位文案 + 当前 turn 变更文件名列表（审查面板转跳目标）。
/// 逐行 diff 内容留待 change3。
struct RightPanelView: View {
    @Environment(ActiveConversationHolder.self) private var activeConversation

    private var files: [String] {
        guard let diff = activeConversation.state?.turnDiff else { return [] }
        return TurnDiffStats.parse(diff).files
    }

    var body: some View {
        if files.isEmpty {
            PanelEmptyState()
        } else {
            List {
                Section {
                    ForEach(files, id: \.self) { path in
                        Label(path, systemImage: "doc.text")
                            .font(.callout).lineLimit(1).truncationMode(.middle)
                    }
                } header: {
                    Text("变更文件")
                } footer: {
                    Text("逐行 diff 即将到来（敬请期待）")
                }
            }
            .listStyle(.insetGrouped)
        }
    }
}
