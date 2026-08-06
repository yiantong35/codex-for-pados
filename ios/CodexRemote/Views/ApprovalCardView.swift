import SwiftUI

/// 多选项审批卡（设计 §6）：内联在中栏对话流中，展示命令/diff 明细 +
/// ① 批准 ② 批准且本会话此前缀不再询问（仅命令审批且有前缀建议时）③ 拒绝。
struct ApprovalCardView: View {
    @Environment(ApprovalStore.self) private var approvals
    let card: ApprovalCard
    var fileContext: FileApprovalContext? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(titleKey, systemImage: titleIcon)
                .font(.headline)
            if card.awaitingRecovery {
                Label("approval.awaitingRecovery", systemImage: "wifi.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(fileContext?.file ?? card.title).font(.callout.monospaced())
            // F4：权限审批展示知情要素——reason + 请求的 network/fileSystem 条目，
            // 用户批准前看清实际授权范围（守 UI 基线：文本可换行/随 Dynamic Type，无固定宽度）。
            if let reason = card.reason, !reason.isEmpty {
                Label(reason, systemImage: "text.bubble")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let context = card.networkApprovalContext {
                Label("\(context.protocol.rawValue)://\(context.host)", systemImage: "network")
                    .font(.caption.monospaced())
            }
            if card.isPermissions {
                if let net = card.requestedNetworkEnabled {
                    Label(net ? "approval.perm.network.on" : "approval.perm.network.off",
                          systemImage: "network")
                        .font(.caption)
                }
                if card.permissionEntries == nil, let fs = card.requestedFileSystem, !fs.isEmpty {
                    ForEach(fs, id: \.self) { path in
                        Label(path, systemImage: "folder")
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                if let entries = card.permissionEntries {
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                        HStack(spacing: 6) {
                            Text(entry.access.rawValue.uppercased())
                                .font(.caption2.bold())
                                .foregroundStyle(entry.access == .deny ? Color.red : Color.secondary)
                            Text(entry.path.displayValue)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                if let depth = card.globScanMaxDepth {
                    HStack(spacing: 4) {
                        Text("approval.perm.globDepth")
                        Text(depth.formatted())
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            if let root = card.grantRoot {
                Label(root, systemImage: "folder.badge.plus")
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let context = fileContext {
                Text("+\(context.added) -\(context.removed)")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                if !context.diff.isEmpty {
                    Text(context.diff)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(12)
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
                // F5：前缀放行仅当服务端提供 amendment 时出现；按钮完整展示该 amendment
                // 的实际授权前缀（非固定文案），使用户看清授权范围。
                if let prefix = Self.prefixButtonState(card: card) {
                    Button {
                        resolve(.approveForSessionPrefix(prefix))
                    } label: {
                        Text("approval.yesPrefixLabel")
                            + Text(" ")
                            + Text(prefix.joined(separator: " ")).monospaced()
                    }
                }
                Spacer()
                Button("approval.no", role: .destructive) { resolve(.deny) }
            }
            .disabled(card.awaitingRecovery)
        }
        .padding()
        .background(.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
