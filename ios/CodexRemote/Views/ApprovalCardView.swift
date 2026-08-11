import SwiftUI
import UIKit

/// 多选项审批卡（设计 §6）：内联在中栏对话流中，展示命令/diff 明细 +
/// ① 批准 ② 批准且本会话此前缀不再询问（仅命令审批且有前缀建议时）③ 拒绝。
struct ApprovalCardView: View {
    @Environment(ApprovalStore.self) private var approvals
    let card: ApprovalCard
    var fileContext: FileApprovalContext? = nil
    @State private var showsFullTitle = false
    @State private var showsFullDiff = false
    @State private var showsFullDetail = false

    private var submissionState: DecisionSubmissionState {
        approvals.submissionState(for: card.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(titleKey, systemImage: titleIcon)
                .font(.headline)
            if card.awaitingRecovery {
                Label("approval.awaitingRecovery", systemImage: "wifi.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            decisionFeedback(submissionState)
            approvalText(Self.sanitizedDisplayText(fileContext?.file ?? card.title),
                         previewLines: 4,
                         expanded: $showsFullTitle)
            // F4：权限审批展示知情要素——reason + 请求的 network/fileSystem 条目，
            // 用户批准前看清实际授权范围（守 UI 基线：文本可换行/随 Dynamic Type，无固定宽度）。
            if let reason = card.reason, !reason.isEmpty {
                Label(Self.sanitizedDisplayText(reason), systemImage: "text.bubble")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let context = card.networkApprovalContext {
                Label(Self.sanitizedDisplayText("\(context.protocol.rawValue)://\(context.host)"),
                      systemImage: "network")
                    .font(.caption.monospaced())
            }
            if card.isPermissions {
                if let net = card.requestedNetworkEnabled {
                    Label(net ? "approval.perm.network.on" : "approval.perm.network.off",
                          systemImage: "network")
                        .font(.caption)
                }
                let legacyPaths = Self.legacyPermissionPaths(card: card)
                if !legacyPaths.isEmpty {
                    ForEach(Array(legacyPaths.enumerated()), id: \.offset) { _, path in
                        permissionPath(path, systemImage: "folder")
                    }
                }
                if let entries = card.permissionEntries {
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(entry.access.rawValue.uppercased())
                                .font(.caption2.bold())
                                .foregroundStyle(entry.access == .deny ? Color.red : Color.secondary)
                            Text(Self.sanitizedDisplayText(entry.path.displayValue))
                                .font(.caption.monospaced())
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
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
                permissionPath(root, systemImage: "folder.badge.plus")
            }
            if let context = fileContext {
                Text("+\(context.added) -\(context.removed)")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                if !context.diff.isEmpty {
                    approvalText(Self.sanitizedDisplayText(context.diff),
                                 previewLines: 12,
                                 expanded: $showsFullDiff)
                }
            }
            if !card.detail.isEmpty {
                    approvalText(Self.sanitizedDisplayText(card.detail),
                                 previewLines: 8,
                                 expanded: $showsFullDetail)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { approvalButtons }
                    .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 8) { approvalButtons }
            }
            .disabled(card.awaitingRecovery || submissionState == .submitting)
        }
        .padding()
        .background(.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func permissionPath(_ path: String, systemImage: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            Text(Self.sanitizedDisplayText(path))
                .font(.caption.monospaced())
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func approvalText(_ text: String,
                              previewLines: Int,
                              expanded: Binding<Bool>) -> some View {
        ExpandableApprovalText(text: text, previewLines: previewLines, expanded: expanded)
    }

    @ViewBuilder
    private func decisionFeedback(_ state: DecisionSubmissionState) -> some View {
        switch state {
        case .idle: EmptyView()
        case .submitting:
            Label("decision.submitting", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption).foregroundStyle(.secondary)
        case .failed:
            Label("decision.failed", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var approvalButtons: some View {
        Button("approval.yes") { resolve(.approve) }
            .buttonStyle(.borderedProminent)
            .minimumHitTarget44()
        if let prefix = Self.prefixButtonState(card: card) {
            let displayPrefix = Self.sanitizedDisplayText(prefix.joined(separator: " "))
            Button {
                resolve(.approveForSessionPrefix(prefix))
            } label: {
                Text("approval.yesPrefixLabel")
                    + Text(" ")
                    + Text(verbatim: displayPrefix).monospaced()
            }
            .fixedSize(horizontal: false, vertical: true)
            .minimumHitTarget44()
            .accessibilityLabel(Text("approval.yesPrefix"))
            .accessibilityValue(Text(verbatim: displayPrefix))
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

    static func legacyPermissionPaths(card: ApprovalCard) -> [String] {
        card.requestedFileSystem ?? []
    }

    /// Approval payloads are untrusted display text. Make line/control/Bidi behavior explicit so the
    /// visible command cannot differ from the string the user is approving.
    static func sanitizedDisplayText(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x09: result += "\\t"
            case 0x0A: result += "\\n\n"
            case 0x0D: result += "\\r"
            case 0x00...0x08, 0x0B...0x0C, 0x0E...0x1F, 0x7F...0x9F,
                 0x061C, 0x200E...0x200F, 0x202A...0x202E, 0x2066...0x2069:
                result += String(format: "[U+%04X]", scalar.value)
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    static func needsTextExpansion(_ text: String,
                                   availableWidth: CGFloat,
                                   previewLines: Int) -> Bool {
        guard availableWidth > 0, previewLines > 0 else { return false }
        let font = UIFont.monospacedSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize,
            weight: .regular
        )
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: availableWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        )
        return bounds.height > font.lineHeight * CGFloat(previewLines) + 1
    }
}

private struct ExpandableApprovalText: View {
    let text: String
    let previewLines: Int
    @Binding var expanded: Bool
    @State private var availableWidth: CGFloat = 0

    private var needsExpansion: Bool {
        ApprovalCardView.needsTextExpansion(
            text,
            availableWidth: availableWidth,
            previewLines: previewLines
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollView {
                Text(verbatim: text)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(expanded ? nil : previewLines)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        GeometryReader { proxy in
                            Color.clear
                                .onAppear { availableWidth = proxy.size.width }
                                .onChange(of: proxy.size.width) { _, width in availableWidth = width }
                        }
                    }
            }
            .frame(maxHeight: expanded ? 320 : nil)

            if needsExpansion {
                Button {
                    withAnimation { expanded.toggle() }
                } label: {
                    Label(expanded ? "approval.showLess" : "approval.showAll",
                          systemImage: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .minimumHitTarget44()
            }
        }
    }
}
