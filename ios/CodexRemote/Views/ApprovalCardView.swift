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
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { approvalButtons }
                    .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 8) { approvalButtons }
            }
            .disabled(card.awaitingRecovery)
        }
        .padding()
        .background(.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var approvalButtons: some View {
        Button("approval.yes") { resolve(.approve) }
            .buttonStyle(.borderedProminent)
            .minimumHitTarget44()
        if let prefix = Self.prefixButtonState(card: card) {
            Button {
                resolve(.approveForSessionPrefix(prefix))
            } label: {
                Text("approval.yesPrefixLabel")
                    + Text(" ")
                    + Text(prefix.joined(separator: " ")).monospaced()
            }
            .lineLimit(1)
            .minimumHitTarget44()
        }
        Button("approval.no", role: .destructive) { resolve(.deny) }
            .minimumHitTarget44()
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

    /// F5：前缀放行仅当服务端在审批请求中提供 `proposedExecpolicyAmendment`。
    /// MUST NOT 本地从命令推导前缀——朴素分词会把 `/bin/sh -c …`、`env FOO=bar git …`
    /// 误放行为过宽的 `/bin/sh`、`env`。文件改动无前缀放行语义。
    /// 无 amendment → nil → 仅提供一次性接受/拒绝。
    static func prefixButtonState(card: ApprovalCard) -> [String]? {
        guard !card.isFileChange else { return nil }
        return card.proposedPrefix
    }
}
