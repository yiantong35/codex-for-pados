import SwiftUI

/// 账户分区（设计 D4）：只读展示共享 EnvironmentStore 的账户/用量/限额。
/// env.attach(rpc:) 的就绪 guard 在容器 SettingsPageView（Task 6）统一挂载；
/// 本视图只读渲染当前 store 状态，nil/未就绪 → 空态。
struct AccountSettingsSectionView: View {
    @Environment(EnvironmentStore.self) private var env

    var body: some View {
        List {
            Section("settings.account") {
                AccountInfoView(account: env.account,
                                usage: env.usage,
                                rateLimits: env.rateLimits)
            }
        }
        .settingsGroupedRowBackground()
        .navigationTitle("settings.account")
    }
}
