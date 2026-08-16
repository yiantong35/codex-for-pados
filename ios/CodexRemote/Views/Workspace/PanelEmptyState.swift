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
                Text(title)
                    .font(.headline)
                    .lineLimit(2, reservesSpace: true)
            } icon: {
                Image(systemName: systemImage)
                    .font(.largeTitle)
            }
        } description: {
            if let description {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(verbatim: " ")
                    .font(.subheadline)
                    .lineLimit(2, reservesSpace: true)
                    .accessibilityHidden(true)
            }
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)
            } else {
                Color.clear
                    .frame(height: 44)
                    .accessibilityHidden(true)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 审查栏没有可显示变更时的共享空态。
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
