import SwiftUI

struct WorkspaceHeader<Content: View>: View {
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(.bar)
    }
}

struct WorkspaceEmptyState: View {
    let title: LocalizedStringKey
    var description: LocalizedStringKey?
    let systemImage: String
    var actionTitle: LocalizedStringKey?
    var action: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label {
                Text(title).font(.headline)
            } icon: {
                Image(systemName: systemImage)
                    .font(.system(size: 40))
            }
        } description: {
            if let description {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 右栏 / 下栏占位空态（design D5：本期无真实内容，后续 change 填充）。
struct PanelEmptyState: View {
    var body: some View {
        WorkspaceEmptyState(
            title: "workspace.panel.empty.title",
            description: "workspace.panel.empty.desc",
            systemImage: "rectangle.dashed"
        )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground))
    }
}
