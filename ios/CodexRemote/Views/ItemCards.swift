import SwiftUI
import UIKit

/// 按 ConversationItem 类型分发渲染的卡片（设计 §3 中栏对话流）。
/// 真实结构见 Domain/ConversationModels.swift：
/// userMessage / agentMessage / commandExecution / fileChange。
struct ItemCard: View {
    let item: ConversationItem
    var onOpenFile: ((String) -> Void)? = nil
    var isStreaming = false
    @Environment(\.locale) private var locale
    @State private var isCommandExpanded = false

    var body: some View {
        switch item {
        case .userMessage(_, let text, let attachments):
            HStack {
                Spacer(minLength: 40)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(attachments.enumerated()), id: \.offset) { index, attachment in
                        UserMessageAttachmentView(
                            attachment: attachment,
                            cacheKey: attachment.cacheKey
                        )
                        .id("\(attachment.cacheKey):\(index)")
                    }
                    if !text.isEmpty {
                        let display = ItemCard.userMessageDisplayText(text)
                        if !display.isEmpty { Text(display).textSelection(.enabled) }
                    }
                }
                    .padding(10)
                    // 用户气泡用主题色淡底（accentColor 橙），不用系统蓝。
                    .background(Color.accentColor.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }

        case .agentMessage(_, let text):
            AgentMarkdownView(text: text, isStreaming: isStreaming)
                .equatable()

        case .reasoning(_, let text):
            // 「正在思考」样式：灰色斜体；有内容显内容，无内容显占位文案。
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "brain")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
                if text.isEmpty {
                    Text("conv.reasoning.thinking")
                        .font(.callout.italic())
                        .foregroundStyle(.secondary)
                } else {
                    let presentation = TextRenderBudget.boundedUTF8Suffix(
                        text, maximumBytes: TextRenderBudget.maximumStreamingBytes
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        if presentation.truncated {
                            Label("conv.reasoning.truncated", systemImage: "ellipsis")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(verbatim: presentation.text)
                            .font(.callout.italic())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        if presentation.truncated {
                            FullTextAccessButton(text: text, title: "conv.reasoning.fullTitle")
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .commandExecution(_, let command, let output, let outputLineCount,
                               let status, let exitCode, let durationMs):
            DisclosureGroup(isExpanded: $isCommandExpanded) {
                if !output.isEmpty {
                    let presentation = TextRenderBudget.commandOutput(output, totalLines: outputLineCount)
                    Text(presentation.text)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(uiColor: .secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    if presentation.isTruncated {
                        Label("conv.output.truncated \(presentation.displayedLines) \(presentation.totalLines)",
                              systemImage: "scissors")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        FullTextAccessButton(text: output, title: "conv.output.fullTitle")
                    }
                }
            } label: {
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
                    Text("conv.output.lines \(outputLineCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                if let action, !action.detail.isEmpty {
                    Text("· \(action.detail)").font(.caption).foregroundStyle(.secondary)
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
                    if !status.isEmpty {
                        Text(verbatim: localizedProtocolStatus(status))
                            .font(.caption).foregroundStyle(.secondary)
                    }
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

    /// 展示用用户消息文本：仅修剪尾部空白/换行（避免气泡底部空行），保留前导与多段结构。
    /// 不做整体 trim —— 保留用户刻意的前导缩进/多段落；daemon 回显的 userMessage 可能带尾部 `\n`。
    static func userMessageDisplayText(_ text: String) -> String {
        String(text.reversed().drop(while: { $0.isWhitespace }).reversed())
    }

    static func agentText(_ text: String) -> AttributedString {
        guard !text.isEmpty else { return AttributedString(" ") }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
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
                    Text(verbatim: localizedProtocolStatus(status))
                        .font(.caption).foregroundStyle(.secondary)
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

    private func localizedProtocolStatus(_ raw: String) -> String {
        L10n.string(Self.protocolStatusLocalizationKey(raw), locale: locale)
    }

    static func protocolStatusLocalizationKey(_ raw: String) -> String {
        let normalized = raw.lowercased().filter(\.isLetter)
        switch normalized {
        case "inprogress", "running", "started": return "conv.status.running"
        case "completed", "complete", "success", "succeeded": return "conv.status.completed"
        case "failed", "failure", "error": return "conv.status.failed"
        case "pending", "queued": return "conv.status.pending"
        case "cancelled", "canceled": return "conv.status.cancelled"
        case "declined", "rejected": return "conv.status.declined"
        default: return "conv.status.unknown"
        }
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

@MainActor
final class MessageImageThumbnailCache {
    typealias Loader = @Sendable (String) async -> FileImageThumbnail?

    private final class Entry: NSObject {
        let image: UIImage
        init(_ image: UIImage) { self.image = image }
    }

    static let shared = MessageImageThumbnailCache()
    private let cache = NSCache<NSString, Entry>()
    private struct InFlight {
        let task: Task<FileImageThumbnail?, Never>
        var waiters: Int
    }
    private var inFlight: [String: InFlight] = [:]
    private var activeLoads = 0
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []
    private let load: Loader
    private static let costLimit = 32 * 1_024 * 1_024

    init(loader: @escaping Loader = { await MessageImageAttachmentDecoder.thumbnail(from: $0) }) {
        self.load = loader
        cache.totalCostLimit = Self.costLimit
    }

    func image(cacheKey: String, source: String) async -> UIImage? {
        let key = cacheKey as NSString
        if let cached = cache.object(forKey: key) { return cached.image }
        let task: Task<FileImageThumbnail?, Never>
        if let existing = inFlight[cacheKey] {
            inFlight[cacheKey]?.waiters += 1
            task = existing.task
        } else {
            let loader = load
            let created = Task { [weak self] in
                await self?.acquireLoadSlot()
                defer { Task { @MainActor [weak self] in self?.releaseLoadSlot() } }
                return await loader(source)
            }
            inFlight[cacheKey] = InFlight(task: created, waiters: 1)
            task = created
        }
        let thumbnail = await withTaskCancellationHandler(operation: {
            await task.value
        }, onCancel: {
            Task { @MainActor [weak self] in self?.cancelWaiter(cacheKey: cacheKey) }
        })
        if Task.isCancelled { return nil }
        if let current = inFlight[cacheKey] {
            if current.waiters <= 1 { inFlight.removeValue(forKey: cacheKey) }
            else { inFlight[cacheKey]?.waiters -= 1 }
        }
        guard let thumbnail else { return nil }
        let image = UIImage(cgImage: thumbnail.cgImage)
        let cost = thumbnail.cgImage.bytesPerRow * thumbnail.cgImage.height
        cache.setObject(Entry(image), forKey: key, cost: cost)
        return Task.isCancelled ? nil : image
    }

    private func cancelWaiter(cacheKey: String) {
        guard let current = inFlight[cacheKey] else { return }
        if current.waiters <= 1 {
            current.task.cancel()
            inFlight.removeValue(forKey: cacheKey)
        } else {
            inFlight[cacheKey]?.waiters -= 1
        }
    }

    private func acquireLoadSlot() async {
        if activeLoads < 2 { activeLoads += 1; return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            loadWaiters.append(continuation)
        }
        activeLoads += 1
    }

    private func releaseLoadSlot() {
        activeLoads = max(0, activeLoads - 1)
        if let next = loadWaiters.first {
            loadWaiters.removeFirst()
            next.resume()
        }
    }
}

private struct UserMessageAttachmentView: View {
    let attachment: UserMessageAttachment
    let cacheKey: String
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
                Label("conv.image.unavailable", systemImage: "photo.badge.exclamationmark")
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel(Text("composer.imageAttached"))
        .task(id: cacheKey) {
            guard attachment.kind == .image else { return }
            guard let decoded = await MessageImageThumbnailCache.shared.image(
                cacheKey: cacheKey, source: attachment.source
            ), !Task.isCancelled else {
                if !Task.isCancelled { decodeFailed = true }
                return
            }
            image = decoded
        }
    }
}

/// 逐行红绿 diff 渲染（统一 diff 文本按行着色）。
struct DiffView: View {
    let diff: String

    var body: some View {
        let allLines = diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let lines = Array(allLines.prefix(DiffRenderBudget.maximumInlineLines))
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(String(line).isEmpty ? " " : String(line))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(lineColor(String(line)))
            }
            if allLines.count > lines.count {
                Label("review.diffTruncated \(lines.count) \(allLines.count)", systemImage: "scissors")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
                FullTextAccessButton(text: diff, title: "review.fullContentTitle")
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

struct BoundedTextPresentation: Equatable {
    let text: String
    let displayedLines: Int
    let totalLines: Int
    let isTruncated: Bool
}

enum TextRenderBudget {
    static let maximumCommandLines = 500
    static let maximumCommandBytes = 128 * 1_024
    static let maximumStreamingBytes = 64 * 1_024
    static let maximumStoredStreamBytes = 2 * 1_024 * 1_024
    static let fullTextPageBytes = 64 * 1_024

    static func boundedUTF8Prefix(_ text: String, maximumBytes: Int) -> (text: String, truncated: Bool) {
        var usedBytes = 0
        var end = text.startIndex
        for character in text {
            let byteCount = String(character).utf8.count
            guard usedBytes + byteCount <= maximumBytes else {
                return (String(text[..<end]), true)
            }
            usedBytes += byteCount
            end = text.index(after: end)
        }
        return (text, false)
    }

    static func boundedUTF8Suffix(_ text: String, maximumBytes: Int) -> (text: String, truncated: Bool) {
        guard text.utf8.count > maximumBytes else { return (text, false) }
        var usedBytes = 0
        var start = text.endIndex
        for character in text.reversed() {
            let byteCount = String(character).utf8.count
            guard usedBytes + byteCount <= maximumBytes else { break }
            usedBytes += byteCount
            start = text.index(before: start)
        }
        return (String(text[start...]), true)
    }

    static func appendingStream(_ current: String, delta: String) -> String {
        guard !delta.isEmpty else { return current }
        var combined = current
        combined.reserveCapacity(current.utf8.count + delta.utf8.count)
        combined += delta
        let overflow = combined.utf8.count - maximumStoredStreamBytes
        guard overflow > 0 else { return combined }
        // Drop only the overflowing prefix. Unlike boundedUTF8Suffix this does not
        // reverse-scan the retained 2 MiB on every 33 ms flush.
        // Walk only the prefix being discarded so the cut remains on a
        // Character boundary even when the byte budget splits a UTF-8 scalar.
        var start = combined.startIndex
        var remaining = overflow
        while start < combined.endIndex, remaining > 0 {
            remaining -= String(combined[start]).utf8.count
            start = combined.index(after: start)
        }
        return String(combined[start...])
    }

    static func commandOutput(_ output: String, totalLines: Int? = nil) -> BoundedTextPresentation {
        let bounded = boundedUTF8Prefix(output, maximumBytes: maximumCommandBytes)
        let source = bounded.text
        var selected: [Substring] = []
        var cursor = source.startIndex
        while cursor < source.endIndex, selected.count < maximumCommandLines {
            if let newline = source[cursor...].firstIndex(of: "\n") {
                selected.append(source[cursor..<newline])
                cursor = source.index(after: newline)
            } else {
                selected.append(source[cursor...])
                cursor = source.endIndex
            }
        }
        if cursor == source.endIndex, source.last == "\n", selected.count < maximumCommandLines {
            selected.append(source[source.endIndex..<source.endIndex])
        }
        let knownTotalLines = totalLines ?? IncrementalTextLineCount.count(output)
        return BoundedTextPresentation(
            text: selected.joined(separator: "\n"),
            displayedLines: selected.count,
            totalLines: knownTotalLines,
            isTruncated: bounded.truncated || cursor < source.endIndex || selected.count < knownTotalLines
        )
    }

    /// Compatibility presentation for tests and callers that need a bounded streaming prefix.
    static func streamingAgentText(_ text: String) -> BoundedTextPresentation {
        let bounded = boundedUTF8Prefix(text, maximumBytes: maximumStreamingBytes)
        let source = bounded.text
        var cursor = source.startIndex
        var end = cursor
        var lines = 0
        while cursor < source.endIndex, lines < MarkdownBlock.maximumInlineLines {
            if let newline = source[cursor...].firstIndex(of: "\n") {
                end = source.index(after: newline)
                cursor = end
            } else {
                end = source.endIndex
                cursor = source.endIndex
            }
            lines += 1
        }
        return BoundedTextPresentation(text: String(source[..<end]), displayedLines: lines,
                                       totalLines: lines, isTruncated: bounded.truncated || end < source.endIndex)
    }
}

enum DiffRenderBudget {
    static let maximumInlineLines = 600
    static let maximumReviewLines = 5_000
}

struct MarkdownBlock: Identifiable, Equatable {
    enum Kind: Equatable {
        case paragraph(String)
        case heading(level: Int, text: String)
        case unordered(String)
        case ordered(marker: String, text: String)
        case code(String)
    }

    let id: Int
    let kind: Kind

    static let maximumInlineBytes = 128 * 1_024
    static let maximumInlineLines = 1_000
    static let maximumInlineBlocks = 512

    static func parse(_ markdown: String) -> [MarkdownBlock] {
        presentation(markdown).blocks
    }

    static func presentation(_ markdown: String) -> MarkdownPresentation {
        let bounded = TextRenderBudget.boundedUTF8Prefix(markdown, maximumBytes: maximumInlineBytes)
        let source = bounded.text
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var code: [String] = []
        var fence: (character: Character, length: Int)?
        var cursor = source.startIndex
        var processedLines = 0

        func append(_ kind: Kind) {
            guard blocks.count < maximumInlineBlocks else { return }
            blocks.append(.init(id: blocks.count, kind: kind))
        }
        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph.removeAll(keepingCapacity: true)
        }

        while cursor < source.endIndex,
              processedLines < maximumInlineLines,
              blocks.count < maximumInlineBlocks {
            let line: String
            if let newline = source[cursor...].firstIndex(of: "\n") {
                line = String(source[cursor..<newline])
                cursor = source.index(after: newline)
            } else {
                line = String(source[cursor...])
                cursor = source.endIndex
            }
            processedLines += 1
            if let activeFence = fence {
                if isClosingFence(line, matching: activeFence) {
                    append(.code(code.joined(separator: "\n")))
                    code.removeAll(keepingCapacity: true)
                    fence = nil
                } else {
                    code.append(line)
                }
                continue
            }
            if let openingFence = openingFence(in: line) {
                flushParagraph()
                fence = openingFence
                continue
            }
            if line.isEmpty { flushParagraph(); continue }

            let hashes = line.prefix { $0 == "#" }.count
            if hashes > 0, hashes <= 6, line.dropFirst(hashes).first == " " {
                flushParagraph()
                append(.heading(level: hashes, text: String(line.dropFirst(hashes + 1))))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                flushParagraph()
                append(.unordered(String(line.dropFirst(2))))
            } else if let dot = line.firstIndex(of: "."),
                      !line[..<dot].isEmpty,
                      line[..<dot].allSatisfy(\.isNumber),
                      line.index(after: dot) < line.endIndex,
                      line[line.index(after: dot)] == " " {
                flushParagraph()
                append(.ordered(marker: String(line[...dot]),
                                text: String(line[line.index(dot, offsetBy: 2)...])))
            } else {
                paragraph.append(line)
            }
        }
        if fence != nil { append(.code(code.joined(separator: "\n"))) }
        flushParagraph()
        return MarkdownPresentation(
            blocks: blocks,
            displayedLines: processedLines,
            isTruncated: bounded.truncated
                || cursor < source.endIndex
                || processedLines >= maximumInlineLines && cursor < source.endIndex
                || blocks.count >= maximumInlineBlocks && cursor < source.endIndex
        )
    }

    private static func openingFence(in line: String) -> (character: Character, length: Int)? {
        let content = line.drop(while: { $0 == " " })
        guard line.count - content.count <= 3,
              let character = content.first,
              character == "`" || character == "~" else { return nil }
        let length = content.prefix { $0 == character }.count
        guard length >= 3 else { return nil }
        let info = content.dropFirst(length)
        if character == "`", info.contains("`") { return nil }
        return (character, length)
    }

    private static func isClosingFence(
        _ line: String,
        matching fence: (character: Character, length: Int)
    ) -> Bool {
        let content = line.drop(while: { $0 == " " })
        guard line.count - content.count <= 3 else { return false }
        let length = content.prefix { $0 == fence.character }.count
        return length >= fence.length
            && content.dropFirst(length).allSatisfy { $0 == " " || $0 == "\t" }
    }
}

struct MarkdownPresentation: Equatable {
    let blocks: [MarkdownBlock]
    let displayedLines: Int
    let isTruncated: Bool
}

private struct AgentMarkdownView: View, Equatable {
    let text: String
    let isStreaming: Bool

    var body: some View {
        Group {
            if isStreaming {
                let presentation = TextRenderBudget.boundedUTF8Suffix(
                    text, maximumBytes: TextRenderBudget.maximumStreamingBytes
                )
                VStack(alignment: .leading, spacing: 6) {
                    if presentation.truncated {
                        Label("conv.agent.streamingTruncated", systemImage: "ellipsis")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(verbatim: presentation.text.isEmpty ? " " : presentation.text)
                }
            } else {
                let presentation = MarkdownBlock.presentation(text)
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(presentation.blocks) { block in
                        switch block.kind {
                        case .paragraph(let value):
                            Text(ItemCard.agentText(value))
                        case .heading(let level, let value):
                            Text(ItemCard.agentText(value))
                                .font(level == 1 ? .title3.bold() : .headline)
                        case .unordered(let value):
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(verbatim: "•")
                                Text(ItemCard.agentText(value))
                            }
                        case .ordered(let marker, let value):
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(verbatim: marker).monospacedDigit()
                                Text(ItemCard.agentText(value))
                            }
                        case .code(let value):
                            ScrollView(.horizontal, showsIndicators: true) {
                                Text(verbatim: value.isEmpty ? " " : value)
                                    .font(.footnote.monospaced())
                                    .padding(8)
                            }
                            .background(Color.secondary.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    if presentation.isTruncated {
                        Label("conv.agent.truncated \(presentation.displayedLines)", systemImage: "scissors")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        FullTextAccessButton(text: text, title: "conv.agent.fullTitle")
                    }
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct FullTextAccessButton: View {
    let text: String
    let title: LocalizedStringKey
    @State private var isPresented = false

    var body: some View {
        Button { isPresented = true } label: {
            Label("common.viewFullContent", systemImage: "arrow.up.left.and.arrow.down.right")
        }
        .font(.caption)
        .minimumHitTarget44()
        .accessibilityLabel(Text("common.viewFullContent"))
        .sheet(isPresented: $isPresented) {
            PagedTextViewer(text: text, title: title, isPresented: $isPresented)
        }
    }
}

struct PagedTextViewer: View {
    let text: String
    let title: LocalizedStringKey
    @Binding var isPresented: Bool
    @State private var page = 0
    private let pageRanges: [Range<String.Index>]

    init(text: String, title: LocalizedStringKey, isPresented: Binding<Bool>) {
        self.text = text
        self.title = title
        _isPresented = isPresented
        pageRanges = Self.pageRanges(for: text)
    }

    private var pageText: Substring { text[pageRanges[page]] }

    var body: some View {
        NavigationStack {
            ScrollView([.horizontal, .vertical], showsIndicators: true) {
                Text(verbatim: pageText.isEmpty ? " " : String(pageText))
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                    .padding()
            }
            .safeAreaInset(edge: .bottom) {
                if pageRanges.count > 1 {
                    HStack {
                        Button("common.previous") { page -= 1 }.disabled(page == 0)
                        Spacer()
                        Text(verbatim: "\(page + 1) / \(pageRanges.count)").monospacedDigit()
                        Spacer()
                        Button("common.next") { page += 1 }.disabled(page == pageRanges.count - 1)
                    }
                    .padding(.horizontal, 16).frame(minHeight: 44).background(.bar)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.done") { isPresented = false }
                }
            }
        }
    }

    static func pageRanges(for text: String) -> [Range<String.Index>] {
        guard !text.isEmpty else { return [text.startIndex..<text.endIndex] }
        var result: [Range<String.Index>] = []
        var start = text.startIndex
        while start < text.endIndex {
            var usedBytes = 0
            var end = start
            while end < text.endIndex {
                let next = text.index(after: end)
                let byteCount = text[end..<next].utf8.count
                guard usedBytes + byteCount <= TextRenderBudget.fullTextPageBytes else { break }
                usedBytes += byteCount
                end = next
            }
            if end == start { end = text.index(after: start) }
            result.append(start..<end)
            start = end
        }
        return result
    }
}
