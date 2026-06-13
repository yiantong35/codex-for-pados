import SwiftUI

/// 多选项审批卡（设计 §6）：内联在中栏对话流中，展示命令/diff 明细 +
/// ① 批准 ② 批准且本会话此前缀不再询问（仅命令审批且有前缀建议时）③ 拒绝。
struct ApprovalCardView: View {
    @Environment(ApprovalStore.self) private var approvals
    let card: ApprovalCard

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(card.isFileChange ? "approval.fileTitle" : "approval.commandTitle",
                  systemImage: card.isFileChange ? "doc.badge.gearshape" : "terminal")
                .font(.headline)
            if card.awaitingRecovery {
                Label("approval.awaitingRecovery", systemImage: "wifi.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(card.title).font(.callout.monospaced())
            if !card.detail.isEmpty {
                Text(card.detail)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(8)
            }
            HStack {
                Button("approval.yes") { resolve(.approve) }
                    .buttonStyle(.borderedProminent)
                if !card.isFileChange, let prefix = card.proposedPrefix ?? defaultPrefix(card.title) {
                    Button("approval.yesPrefix") { resolve(.approveForSessionPrefix(prefix)) }
                }
                Spacer()
                Button("approval.no", role: .destructive) { resolve(.deny) }
            }
            .disabled(card.awaitingRecovery)
        }
        .padding()
        .background(.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func resolve(_ choice: ApprovalChoice) {
        Task { await approvals.resolve(card: card, choice: choice) }
    }

    /// 无 server 建议前缀时，用命令首 token 作前缀放行。
    private func defaultPrefix(_ command: String) -> [String]? {
        let toks = command.split(separator: " ").map(String.init)
        return toks.isEmpty ? nil : [toks[0]]
    }
}
