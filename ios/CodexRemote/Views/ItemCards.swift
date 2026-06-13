import SwiftUI

/// 按 ConversationItem 类型分发渲染的卡片（设计 §3 中栏对话流）。
/// 真实结构见 Domain/ConversationModels.swift：
/// userMessage / agentMessage / commandExecution / fileChange。
struct ItemCard: View {
    let item: ConversationItem

    var body: some View {
        switch item {
        case .userMessage(_, let text):
            HStack {
                Spacer(minLength: 40)
                Text(text)
                    .textSelection(.enabled)
                    .padding(10)
                    .background(.blue.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }

        case .agentMessage(_, let text):
            // MVP：Markdown 行内渲染（代码块/格式）。空串时占位，避免抖动。
            Text(text.isEmpty ? " " : LocalizedStringKey(text))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .commandExecution(_, let command, let output, let status, let exitCode, let durationMs):
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Label {
                        Text(command).font(.callout.monospaced())
                    } icon: {
                        commandStatusIcon(status)
                    }
                    Spacer(minLength: 8)
                    commandStatusBadge(status: status, exitCode: exitCode, durationMs: durationMs)
                }
                if !output.isEmpty {
                    Text(output)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.black.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .fileChange(_, let file, let added, let removed, let diff):
            DisclosureGroup {
                DiffView(diff: diff)
            } label: {
                HStack {
                    Image(systemName: "doc.text")
                    Text(file).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text("+\(added)").foregroundStyle(.green).font(.footnote.monospaced())
                    Text("-\(removed)").foregroundStyle(.red).font(.footnote.monospaced())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 命令状态渲染

    /// 行首图标：运行中转圈 / 完成对勾 / 失败叉 / 拒绝禁止符。
    @ViewBuilder
    private func commandStatusIcon(_ status: CommandStatus) -> some View {
        switch status {
        case .inProgress:
            ProgressView().controlSize(.small)
        case .completed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .declined:
            Image(systemName: "nosign").foregroundStyle(.secondary)
        }
    }

    /// 行尾徽标：状态文案 + 退出码 + 耗时。
    @ViewBuilder
    private func commandStatusBadge(status: CommandStatus, exitCode: Int?, durationMs: Int?) -> some View {
        HStack(spacing: 6) {
            Text(statusLabelKey(status))
                .foregroundStyle(statusColor(status))
            if let exitCode {
                Text("conv.cmd.exitCode \(exitCode)")
                    .foregroundStyle(exitCode == 0 ? .secondary : Color.red)
            }
            if let durationMs {
                Text("conv.cmd.duration \(durationMs)")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption.monospaced())
    }

    private func statusLabelKey(_ status: CommandStatus) -> LocalizedStringKey {
        switch status {
        case .inProgress: return "conv.cmd.running"
        case .completed:  return "conv.cmd.completed"
        case .failed:     return "conv.cmd.failed"
        case .declined:   return "conv.cmd.declined"
        }
    }

    private func statusColor(_ status: CommandStatus) -> Color {
        switch status {
        case .inProgress: return .orange
        case .completed:  return .green
        case .failed:     return .red
        case .declined:   return .secondary
        }
    }
}

/// 逐行红绿 diff 渲染（统一 diff 文本按行着色）。
struct DiffView: View {
    let diff: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(diff.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                Text(String(line).isEmpty ? " " : String(line))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(lineColor(String(line)))
            }
        }
        .padding(.top, 4)
    }

    private func lineColor(_ l: String) -> Color {
        if l.hasPrefix("+") { return .green.opacity(0.15) }
        if l.hasPrefix("-") { return .red.opacity(0.15) }
        return .clear
    }
}
