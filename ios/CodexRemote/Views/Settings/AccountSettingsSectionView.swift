import SwiftUI

/// 账户分区占位（Task 5 填充读 EnvironmentStore 只读渲染）。
struct AccountSettingsSectionView: View {
    var body: some View {
        List { Text(verbatim: "account placeholder") }
            .navigationTitle("settings.account")
    }
}
