import SwiftUI
import UIKit

/// 按 ConversationItem 类型分发渲染的卡片（设计 §3 中栏对话流）。
/// 真实结构见 Domain/ConversationModels.swift：
/// userMessage / agentMessage / commandExecution / fileChange。
struct ItemCard: View {
    let item: ConversationItem
    var onOpenFile: ((String) -> Void)? = nil

    var body: some View {
        switch item {
        case .userMessage(let itemID, let text, let attachments):
            HStack {
                Spacer(minLength: 40)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(attachments.enumerated()), id: \.offset) { index, attachment in
                        UserMessageAttachmentView(attachment: attachment)
                            .id("\(itemID):\(index)")
                    }
                    if !text.isEmpty {
                        Text(text).textSelection(.enabled)
                    }
                }
                    .padding(10)
                    // 用户气泡用主题色淡底（accentColor 橙），不用系统蓝。
                    .background(Color.accentColor.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }

        case .agentMessage(_, let text):
            // MVP：Markdown 行内渲染（代码块/格式）。空串时占位，避免抖动。
            Text(text.isEmpty ? " " : LocalizedStringKey(text))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .reasoning(_, let text):
            // 「正在思考」样式：灰色斜体；有内容显内容，无内容显占位文案。
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "brain")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
                Text(text.isEmpty ? LocalizedStringKey("conv.reasoning.thinking") : LocalizedStringKey(text))
                    .font(.callout.italic())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
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

        case .unknown(_, let type):
            HStack(spacing: 6) {
                Image(systemName: "questionmark.diamond").foregroundStyle(.secondary)
                Text("conv.item.unknown").font(.caption).foregroundStyle(.secondary)
                if !type.isEmpty {
                    Text(type).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: .infinity, alignment: .leading)

        case .mcpToolCall(_, let server, let tool, let status, let result, let durationMs):
            toolCard(icon: "wrench.and.screwdriver",
                     prefixKey: "conv.item.mcp",
                     title: server.isEmpty ? tool : "\(server) / \(tool)",
                     status: status, detail: result, durationMs: durationMs)

        case .dynamicToolCall(_, let namespace, let tool, let status, let success):
            let effStatus = status.isEmpty
                ? (success == true ? "success" : (success == false ? "failed" : ""))
                : status
            toolCard(icon: "hammer",
                     prefixKey: "conv.item.dynamicTool",
                     title: namespace.isEmpty ? tool : "\(namespace):\(tool)",
                     status: effStatus, detail: "", durationMs: nil)

        case .webSearch(_, let query, let action):
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                Text("conv.item.webSearch").font(.caption).foregroundStyle(.secondary)
                Text(query).font(.callout).lineLimit(2)
                if !action.isEmpty {
                    Text("· \(action)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .contextCompaction:
            eventBar(icon: "arrow.down.right.and.arrow.up.left", textKey: "conv.item.compaction")

        case .enteredReviewMode:
            eventBar(icon: "eye", textKey: "conv.item.reviewEntered")

        case .exitedReviewMode:
            eventBar(icon: "eye.slash", textKey: "conv.item.reviewExited")

        case .hookPrompt(_, let fragments):
            eventBar(icon: "link", textKey: "conv.item.hook", detail: fragments)

        case .imageGeneration(_, let status, let revisedPrompt, let savedPath):
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                    Text("conv.item.imageGen").font(.caption).foregroundStyle(.secondary)
                    if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
                    Spacer(minLength: 0)
                }
                if !revisedPrompt.isEmpty {
                    Text(revisedPrompt).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                }
                if !savedPath.isEmpty {
                    fileInspectionButton(path: savedPath)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .imageView(_, let path):
            fileInspectionButton(path: path)
            .frame(maxWidth: .infinity, alignment: .leading)

        case .plan(_, let text):
            eventBar(icon: "list.bullet.clipboard", textKey: "conv.item.plan", detail: text)

        // 子智能体项聚合进右栏子智能体面板（state.subAgents），主对话流不重复渲染。
        case .collabAgentToolCall, .subAgentActivity:
            EmptyView()
        }
    }

    @ViewBuilder
    private func fileInspectionButton(path: String) -> some View {
        if let onOpenFile {
            Button { onOpenFile(path) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "photo.on.rectangle")
                    Text(path).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Text("conv.item.inspectFile").font(.caption)
                    Image(systemName: "chevron.right").font(.caption2)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .minimumHitTarget44()
        } else {
            Label(path, systemImage: "photo.on.rectangle")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
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

    // MARK: - 通用卡片帮助函数

    /// 工具类卡片：[icon] 前缀 · 标题 · 状态 · 结果摘要 · 耗时。
    @ViewBuilder
    private func toolCard(icon: String, prefixKey: LocalizedStringKey, title: String,
                          status: String, detail: String, durationMs: Int?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(.secondary)
                Text(prefixKey).font(.caption).foregroundStyle(.secondary)
                Text(title).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                if !status.isEmpty {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                if let durationMs {
                    Text("conv.cmd.duration \(durationMs)")
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
            if !detail.isEmpty {
                Text(detail).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 事件类单行提示条：[icon] 文案 · 可选详情，次要色。
    @ViewBuilder
    private func eventBar(icon: String, textKey: LocalizedStringKey, detail: String = "") -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.caption).foregroundStyle(.secondary)
            Text(textKey).font(.caption).foregroundStyle(.secondary)
            if !detail.isEmpty {
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct UserMessageAttachmentView: View {
    let attachment: UserMessageAttachment
    @State private var image: UIImage?
    @State private var decodeFailed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 220, maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else if attachment.kind == .image, !decodeFailed {
                ProgressView()
                    .frame(width: 44, height: 44)
            } else if attachment.kind == .localImage {
                Label {
                    Text(attachment.source)
                        .font(.caption.monospaced())
                        .lineLimit(2)
                        .truncationMode(.middle)
                } icon: {
                    Image(systemName: "photo")
                }
                .foregroundStyle(.secondary)
            } else {
                Label("composer.imageAttached", systemImage: "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel(Text("composer.imageAttached"))
        .task {
            guard attachment.kind == .image else { return }
            guard let thumbnail = await MessageImageAttachmentDecoder.thumbnail(from: attachment.source),
                  !Task.isCancelled else {
                if !Task.isCancelled { decodeFailed = true }
                return
            }
            image = UIImage(cgImage: thumbnail.cgImage)
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
