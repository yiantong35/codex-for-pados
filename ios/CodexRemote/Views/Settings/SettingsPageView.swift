import SwiftUI

/// 设置页容器（ipad-settings-page 设计 D1/D2）：左导航 List + 右 detail switch。
/// 以 .sheet 呈现（Task 6 接线 env.attach + gear 触发）。默认选中 .account。
struct SettingsPageView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ConnectionStore.self) private var connection
    @Environment(EnvironmentStore.self) private var env
    @State private var selection: SettingsSection? = .default

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selection) { section in
                Label(section.label, systemImage: section.icon)
                    .tag(section)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // 左上角关闭：明确的 X 按钮，符合 iPad sheet 惯例。
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .accessibilityLabel(Text("settings.close"))
                    }
                }
                // 右上角完成：醒目主操作按钮（borderedProminent）而非裸文字。
                ToolbarItem(placement: .confirmationAction) {
                    Button("settings.done") { dismiss() }
                        .buttonStyle(.borderedProminent)
                }
            }
        } detail: {
            switch selection ?? .default {
            case .account:    AccountSettingsSectionView()
            case .appearance: AppearanceSettingsSectionView()
            case .language:   LanguageSettingsSectionView()
            }
        }
        .task(id: connection.phase) {
            guard connection.phase == .ready, let rpc = connection.rpc else { return }
            await env.attach(rpc: rpc)
        }
    }
}
