import SwiftUI

/// 多选项审批卡（设计 §6）：内联在中栏对话流中，展示命令/diff 明细 +
/// ① 批准 ② 批准且本会话此前缀不再询问（仅命令审批且有前缀建议时）③ 拒绝。
struct ApprovalCardView: View {
    @Environment(ApprovalStore.self) private var approvals
    let card: ApprovalCard

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(titleKey, systemImage: titleIcon)
                .font(.headline)
            if card.awaitingRecovery {
                Label("approval.awaitingRecovery", systemImage: "wifi.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(card.title).font(.callout.monospaced())
            // F4：权限审批展示知情要素——reason + 请求的 network/fileSystem 条目，
            // 用户批准前看清实际授权范围（守 UI 基线：文本可换行/随 Dynamic Type，无固定宽度）。
            if card.isPermissions {
                if let reason = card.reason, !reason.isEmpty {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let net = card.requestedNetworkEnabled {
                    Label(net ? "approval.perm.network.on" : "approval.perm.network.off",
                          systemImage: "network")
                        .font(.caption)
                }
                if let fs = card.requestedFileSystem, !fs.isEmpty {
                    ForEach(fs, id: \.self) { path in
                        Label(path, systemImage: "folder")
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
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

    /// 卡片标题键：权限 / 文件 / 命令三态。
    private var titleKey: LocalizedStringKey {
        if card.isPermissions { return "approval.permissionTitle" }
        return card.isFileChange ? "approval.fileTitle" : "approval.commandTitle"
    }

    private var titleIcon: String {
        if card.isPermissions { return "lock.shield" }
        return card.isFileChange ? "doc.badge.gearshape" : "terminal"
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
