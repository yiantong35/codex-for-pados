import SwiftUI
import Observation
import RelayProtocol

/// relay 配对导入的错误（面向用户的明确文案 key）。
enum PairingImportError: LocalizedError, Equatable {
    case empty
    case badFormat
    case expired

    var errorDescription: String? {
        switch self {
        case .empty:     return String(localized: "relayImport.error.empty")
        case .badFormat: return String(localized: "relayImport.error.badFormat")
        case .expired:   return String(localized: "relayImport.error.expired")
        }
    }
}

/// iPad 侧粘贴导入 relay 配对载荷的 ViewModel（批次 D 末 task）。
/// 纯逻辑，`makeMachineConfig(now:)` 便于测试注入时钟；生产默认取当前时间戳。
/// 解析走 RelayProtocol.PairingPayload(parsing:)，过期走 isExpired(now:)。
@Observable
@MainActor
final class RelayPairingImportViewModel {
    var pasted: String = ""

    /// 从粘贴串解析并校验，成功返回 `.relay(pairing:)` 的 MachineConfig。
    /// - 空/纯空白 → `.empty`
    /// - 解析失败（scheme/host/缺字段）→ `.badFormat`
    /// - 已过期 → `.expired`
    /// - `now`：当前 Unix 秒；默认取系统时间，测试可注入。
    func makeMachineConfig(now: Int64 = Int64(Date().timeIntervalSince1970)) throws -> MachineConfig {
        let text = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw PairingImportError.empty }

        let payload: PairingPayload
        do {
            payload = try PairingPayload(parsing: text)
        } catch {
            throw PairingImportError.badFormat
        }

        guard !payload.isExpired(now: now) else { throw PairingImportError.expired }

        // displayName 回落到 relayURL 的 host（无则用 relayURL 原串），保证 MachineConfig 非空显示名。
        let name = URL(string: payload.relayURL)?.host ?? payload.relayURL
        return MachineConfig(displayName: name.isEmpty ? nil : name,
                             connection: .relay(pairing: text))
    }
}

/// relay 配对粘贴导入界面：粘贴框 + 粘贴/导入按钮 + 错误提示。
/// 由 MachineFormView 经 NavigationLink 进入，成功导入后回调交上层保存并 dismiss。
///
/// UI 基线（横竖屏 + 键盘）：ScrollView 包裹 + `.scrollDismissesKeyboard(.interactively)`
/// 防软键盘遮挡；卡片 `maxWidth: 480` 居中，横竖屏都可用；TextEditor 走标准文本输入，
/// 外接键盘可正常输入，Esc 取消（继承 MachineFormView 工具栏的 cancelAction）。
struct RelayPairingImportView: View {
    @Environment(SessionsManager.self) private var sessions
    @Environment(\.dismiss) private var dismiss

    @State private var vm = RelayPairingImportViewModel()
    @State private var errorText: String?

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()

            ScrollView {
                card
                    .frame(maxWidth: 480)
                    .frame(maxWidth: .infinity)
                    .padding(24)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .navigationTitle("relayImport.title")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("relayImport.import") { importPairing() }
                    .disabled(vm.pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("relayImport.hint")
                .font(.footnote)
                .foregroundStyle(.secondary)

            editor

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button {
                    if let s = UIPasteboard.general.string {
                        vm.pasted = s
                        errorText = nil
                    }
                } label: {
                    Label("relayImport.paste", systemImage: "doc.on.clipboard")
                        .font(.callout)
                }
                Spacer()
            }
        }
        .padding(28)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 16, x: 0, y: 6)
    }

    /// 多行粘贴框：TextEditor（配对串较长），带占位提示 + 圆角描边。
    private var editor: some View {
        ZStack(alignment: .topLeading) {
            if vm.pasted.isEmpty {
                Text("relayImport.placeholder")
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $vm.pasted)
                .font(.system(.footnote, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .scrollContentBackground(.hidden)
                .frame(minHeight: 96)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .onChange(of: vm.pasted) { errorText = nil }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.tertiarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(.separator), lineWidth: 0.5)
        )
    }

    /// 解析导入：成功交 addMachineAndConnect（切过去 + 连接），失败展示明确文案。
    private func importPairing() {
        do {
            let m = try vm.makeMachineConfig()
            if sessions.addMachineAndConnect(m) {
                dismiss()
            }
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription
                ?? String(localized: "relayImport.error.badFormat")
        }
    }
}
