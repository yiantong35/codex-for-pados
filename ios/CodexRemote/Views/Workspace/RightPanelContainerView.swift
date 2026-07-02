import SwiftUI

/// 右栏 tab 标识（D1）。当前两个 tab：审查 / 文件。
enum RightPanelTab: CaseIterable, Identifiable {
    case review, files
    var id: Self { self }
    var label: String { self == .review ? "审查" : "文件" }
}

/// 右边栏 tab 容器（D1）：顶部自绘 tab 条 + 按枚举 switch 渲染，不用 SwiftUI TabView
/// （避免其在 NavigationSplitView 右栏内的额外手势区与尺寸重算）。
struct RightPanelContainerView: View {
    /// 当前选中 thread 的 cwd：审查「全量」拉取 + 文件浏览根均需要。
    var cwd: String?

    @State private var selectedTab: RightPanelTab = .review

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            switch selectedTab {
            case .review:
                RightPanelView(cwd: cwd)   // Task 7 换成 ReviewTabView
            case .files:
                Color(.systemBackground)   // Task 11 换成 FileBrowserView
            }
        }
    }

    // 自绘分段 tab 条（非 Picker/TabView）。
    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(RightPanelTab.allCases) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    Text(tab.label)
                        .font(.subheadline)
                        .fontWeight(selectedTab == tab ? .semibold : .regular)
                        .foregroundStyle(selectedTab == tab ? Color.accentColor : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(tab.label))
            }
        }
        .background(.bar)
    }
}
