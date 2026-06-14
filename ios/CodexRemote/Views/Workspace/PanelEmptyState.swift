import SwiftUI

/// 右栏 / 下栏占位空态（design D5：本期无真实内容，后续 change 填充）。
struct PanelEmptyState: View {
    var body: some View {
        ContentUnavailableView("workspace.panel.empty.title",
                               systemImage: "rectangle.dashed",
                               description: Text("workspace.panel.empty.desc"))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground))
    }
}
