import SwiftUI

/// 环境面板（批次④）：账户(只读) + 模型(列出/切换) + curated 配置(读写)。
/// 数据来自共享 daemon；配置/模型写入全局生效。
struct EnvironmentPanelView: View {
    @Environment(EnvironmentStore.self) private var env
    @Environment(ConnectionStore.self) private var connection
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                accountSection
                modelSection
                configSection
            }
            .navigationTitle("env.title")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("env.done") { dismiss() }
                }
            }
            .task(id: connection.phase) {
                guard connection.phase == .ready, let rpc = connection.rpc else { return }
                await env.attach(rpc: rpc)
            }
        }
    }

    @ViewBuilder private var accountSection: some View {
        Section("env.account") {
            switch env.account {
            case .chatgpt(let email, let plan):
                LabeledContent("env.account.email", value: email)
                LabeledContent("env.account.plan", value: plan)
            case .apiKey:        LabeledContent("env.account", value: "API Key")
            case .amazonBedrock: LabeledContent("env.account", value: "Amazon Bedrock")
            case nil:            Text("env.account.none").foregroundStyle(.secondary)
            }
            if let u = env.usage, let life = u.lifetimeTokens {
                LabeledContent("env.usage.lifetime", value: "\(life)")
            }
            if let w = env.rateLimits?.primary {
                LabeledContent("env.rate.used", value: String(format: "%.0f%%", w.usedPercent))
                if let r = w.resetsAt {
                    LabeledContent("env.rate.reset", value: Self.reset(r))
                }
            }
        }
    }

    @ViewBuilder private var modelSection: some View {
        Section("env.model") {
            if env.models.isEmpty {
                Text("env.model.none").foregroundStyle(.secondary)
            } else {
                ForEach(env.models, id: \.self) { m in
                    Button {
                        Task { await env.switchModel(m) }
                    } label: {
                        HStack {
                            Text(m).foregroundStyle(.primary)
                            Spacer()
                            if env.config?.model == m { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var configSection: some View {
        Section {
            configPicker("env.cfg.approval", keyPath: "approval_policy",
                         options: ["untrusted", "on-failure", "on-request", "never"],
                         current: { if case .simple(let s) = env.config?.approvalPolicy { return s }; return nil },
                         editable: { if case .granular = env.config?.approvalPolicy { return false }; return true })
            configPicker("env.cfg.sandbox", keyPath: "sandbox_mode",
                         options: ["read-only", "workspace-write", "danger-full-access"],
                         current: { env.config?.sandboxMode }, editable: { true })
            configPicker("env.cfg.effort", keyPath: "model_reasoning_effort",
                         options: ["low", "medium", "high"],
                         current: { env.config?.modelReasoningEffort }, editable: { true })
        } header: {
            Text("env.config")
        } footer: {
            Text("env.config.global")
        }
    }

    @ViewBuilder
    private func configPicker(_ titleKey: LocalizedStringKey, keyPath: String, options: [String],
                              current: @escaping () -> String?, editable: @escaping () -> Bool) -> some View {
        if editable() {
            Picker(titleKey, selection: Binding(
                get: { current() ?? "" },
                set: { v in if !v.isEmpty { Task { await env.writeConfig(keyPath: keyPath, stringValue: v) } } }
            )) {
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
        } else {
            LabeledContent(titleKey) { Text(current() ?? "granular").foregroundStyle(.secondary) }
        }
    }

    private static func reset(_ ts: Double) -> String {
        RelativeDateTimeFormatter().localizedString(for: Date(timeIntervalSince1970: ts), relativeTo: Date())
    }
}
