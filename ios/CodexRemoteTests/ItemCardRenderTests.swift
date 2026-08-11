import XCTest
import SwiftUI
@testable import CodexRemote

// ItemCard 渲染存在性断言：构造每个 case 的卡片，确保 body 不崩溃。
// SwiftUI View 的 body 在单测中求值以覆盖 switch 分支。
@MainActor
final class ItemCardRenderTests: XCTestCase {
    // 各 case 的用例随 Task 逐步补齐。
    func testUnknownCardBodyDoesNotCrash() {
        _ = ItemCard(item: .unknown(id: "x", type: "futureType")).body
    }

    func testToolCardsBodyDoNotCrash() {
        _ = ItemCard(item: .mcpToolCall(id: "1", server: "fs", tool: "read",
                                        status: "completed", result: "ok", durationMs: 8)).body
        _ = ItemCard(item: .dynamicToolCall(id: "2", namespace: "shell", tool: "exec",
                                            status: "completed", success: true)).body
        _ = ItemCard(item: .webSearch(
            id: "3", query: "swift", action: .openPage(url: "https://swift.org")
        )).body
    }

    func testEventCardsBodyDoNotCrash() {
        _ = ItemCard(item: .contextCompaction(id: "1")).body
        _ = ItemCard(item: .enteredReviewMode(id: "2")).body
        _ = ItemCard(item: .exitedReviewMode(id: "3")).body
        _ = ItemCard(item: .hookPrompt(id: "4", fragments: "hook body")).body
    }

    func testImageAndPlanCardsBodyDoNotCrash() {
        _ = ItemCard(item: .imageGeneration(id: "1", status: "completed",
                                            revisedPrompt: "a cat", savedPath: "/tmp/c.png")).body
        _ = ItemCard(item: .imageView(id: "2", path: "/tmp/x.png")).body
        _ = ItemCard(item: .plan(id: "3", text: "读\n写")).body
        _ = ItemCard(item: .collabAgentToolCall(id: "4")).body
        _ = ItemCard(item: .subAgentActivity(id: "5")).body
    }

    func testMessageImageDataURLIsStrictAndSizeBounded() {
        let bytes = Data("image".utf8)
        let valid = "data:image/png;base64," + bytes.base64EncodedString()
        XCTAssertEqual(MessageImageAttachmentDecoder.imageData(from: valid), bytes)
        XCTAssertNil(MessageImageAttachmentDecoder.imageData(from: valid + "!"))

        let oversized = "data:image/png;base64,"
            + String(repeating: "A", count: MessageImageAttachmentDecoder.maximumDataURLBytes)
        XCTAssertNil(MessageImageAttachmentDecoder.imageData(from: oversized))
    }

    func testMessageImageBuildsPixelBudgetedThumbnail() async throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 3_000, height: 300))
        let png = renderer.pngData { context in
            UIColor.systemBlue.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 3_000, height: 300))
        }
        let source = "data:image/png;base64," + png.base64EncodedString()

        let decoded = await MessageImageAttachmentDecoder.thumbnail(from: source)
        let thumbnail = try XCTUnwrap(decoded)
        XCTAssertLessThanOrEqual(max(thumbnail.cgImage.width, thumbnail.cgImage.height),
                                 FileImageThumbnailDecoder.maximumThumbnailDimension)
    }

    func testMessageImageCacheKeySurvivesOptimisticIDReplacementAndDeduplicatesLoad() async throws {
        let source = "data:image/png;base64,c2FtZQ=="
        let optimistic = UserMessageAttachment(kind: .image, source: source)
        let authoritative = UserMessageAttachment(kind: .image, source: source)
        XCTAssertEqual(optimistic.cacheKey, authoritative.cacheKey)

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2))
        let image = renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        let thumbnail = FileImageThumbnail(cgImage: try XCTUnwrap(image.cgImage))
        let probe = ImageThumbnailLoaderProbe(thumbnail: thumbnail)
        let cache = MessageImageThumbnailCache(loader: { source in await probe.load(source) })

        let first = Task { await cache.image(cacheKey: optimistic.cacheKey, source: source) }
        let second = Task { await cache.image(cacheKey: authoritative.cacheKey, source: source) }
        _ = await (first.value, second.value)

        let loadCount = await probe.loadCount
        XCTAssertEqual(loadCount, 1)
    }

    func test_protocolStatusesMapToUserFacingLocalizationKeys() {
        XCTAssertEqual(ItemCard.protocolStatusLocalizationKey("in_progress"), "conv.status.running")
        XCTAssertEqual(ItemCard.protocolStatusLocalizationKey("success"), "conv.status.completed")
        XCTAssertEqual(ItemCard.protocolStatusLocalizationKey("RPC_INTERNAL_42"), "conv.status.unknown")
    }

    func testCommandOutputBudgetBoundsLinesAndBytes() {
        let lines = (0..<800).map { "line-\($0)-" + String(repeating: "x", count: 400) }
        let presentation = TextRenderBudget.commandOutput(lines.joined(separator: "\n"))

        XCTAssertTrue(presentation.isTruncated)
        XCTAssertLessThanOrEqual(presentation.displayedLines, TextRenderBudget.maximumCommandLines)
        XCTAssertLessThanOrEqual(presentation.text.utf8.count, TextRenderBudget.maximumCommandBytes)
        XCTAssertEqual(presentation.totalLines, 800)
    }

    func testCommandLineCountCanBeMaintainedFromDeltas() {
        var count = 0
        var empty = true
        for delta in ["one\n", "two", "\nthree"] {
            count = IncrementalTextLineCount.appending(
                currentCount: count, currentIsEmpty: empty, delta: delta
            )
            empty = false
        }
        XCTAssertEqual(count, 3)

        let presentation = TextRenderBudget.commandOutput(
            String(repeating: "line\n", count: 20_000), totalLines: 20_001
        )
        XCTAssertEqual(presentation.totalLines, 20_001)
        XCTAssertTrue(presentation.isTruncated)
    }

    func testDiffBudgetsKeepInlineSmallerThanDedicatedReview() {
        XCTAssertGreaterThan(DiffRenderBudget.maximumInlineLines, 0)
        XCTAssertGreaterThan(DiffRenderBudget.maximumReviewLines, DiffRenderBudget.maximumInlineLines)
    }

    func testAgentTextDoesNotTreatProtocolLikeTextAsLocalizationKey() {
        XCTAssertEqual(String(ItemCard.agentText("common.cancel").characters), "common.cancel")
        XCTAssertEqual(String(ItemCard.agentText("**bold**").characters), "bold")
    }

    func testAgentMarkdownPreservesParagraphListAndCodeBlockBoundaries() {
        let blocks = MarkdownBlock.parse("alpha\n\nbeta\n\n- one\n- two\n\n```swift\nlet x = 1\n```")
        XCTAssertEqual(blocks.map(\.kind), [
            .paragraph("alpha"),
            .paragraph("beta"),
            .unordered("one"),
            .unordered("two"),
            .code("let x = 1"),
        ])
    }

    func testAgentMarkdownParsingHasHardByteLineAndBlockBudgets() {
        let markdown = String(repeating: "- item\n", count: 100_000)
        let presentation = MarkdownBlock.presentation(markdown)

        XCTAssertTrue(presentation.isTruncated)
        XCTAssertLessThanOrEqual(presentation.displayedLines, MarkdownBlock.maximumInlineLines)
        XCTAssertLessThanOrEqual(presentation.blocks.count, MarkdownBlock.maximumInlineBlocks)
    }

    func testInteractiveDisplaySanitizerExposesBidiAndControls() {
        let raw = "Approve\u{202E}txt\u{2066}\u{0007}"
        XCTAssertEqual(
            UntrustedDisplayText.sanitize(raw),
            "Approve[U+202E]txt[U+2066][U+0007]"
        )
    }

    func testAgentMarkdownFenceTracksCharacterAndMinimumLength() {
        let backticks = MarkdownBlock.parse("````markdown\n```swift\nlet x = 1\n```\n````")
        XCTAssertEqual(backticks.map(\.kind), [
            .code("```swift\nlet x = 1\n```")
        ])

        let tildes = MarkdownBlock.parse("~~~swift\nlet y = 2\n~~~")
        XCTAssertEqual(tildes.map(\.kind), [.code("let y = 2")])
    }

    func testReviewFullTextContainsTailBeyondRenderBudget() {
        let lines = (0...DiffRenderBudget.maximumReviewLines).map {
            DiffLine(kind: .add, text: "line-\($0)", oldLineNo: nil, newLineNo: $0 + 1)
        }
        let raw = "diff --git a/large.swift b/large.swift\n@@ -1 +1 @@\n-tail"
        let file = DiffFile(path: "large.swift", oldPath: nil, kind: .modify,
                            hunks: [DiffHunk(lines: lines)], rawDiff: raw)
        XCTAssertEqual(ReviewPanelView.fullText(for: file), raw)
    }

    // MARK: - F5（P1）会话前缀放行仅源自服务端 amendment

    private func cmdCard(title: String, prefix: [String]?, isFile: Bool = false) -> ApprovalCard {
        ApprovalCard(id: .string("c"), method: isFile ? ServerRequestMethod.fileApprovalV2 : ServerRequestMethod.cmdApprovalV2,
                     threadId: "t", title: title, detail: "/w",
                     proposedPrefix: prefix, isFileChange: isFile, isPermissions: false,
                     reason: nil, requestedNetworkEnabled: nil, requestedFileSystem: nil)
    }

    /// 无服务端 amendment：不提供前缀放行、绝不从 command[0] 本地推导。
    func test_prefix_allow_absent_without_amendment() {
        let card = cmdCard(title: "/bin/sh -c 'rm x'", prefix: nil)
        XCTAssertNil(ApprovalCardView.prefixButtonState(card: card))
    }

    /// 有服务端 amendment：展示实际前缀（原样返回，不做本地覆写）。
    func test_prefix_allow_shows_actual_amendment() {
        let card = cmdCard(title: "git status", prefix: ["git", "status"])
        XCTAssertEqual(ApprovalCardView.prefixButtonState(card: card), ["git", "status"])
    }

    /// 文件改动无前缀放行语义：即便误带 prefix 也不提供。
    func test_prefix_allow_absent_for_file_change() {
        let card = cmdCard(title: "main.swift", prefix: ["should", "ignore"], isFile: true)
        XCTAssertNil(ApprovalCardView.prefixButtonState(card: card))
    }

    func test_approval_expand_control_only_appears_for_truncated_content() {
        XCTAssertFalse(ApprovalCardView.needsTextExpansion(
            "git status",
            availableWidth: 240,
            previewLines: 8
        ))
        XCTAssertTrue(ApprovalCardView.needsTextExpansion(
            String(repeating: "a long diff line that wraps ", count: 40),
            availableWidth: 180,
            previewLines: 8
        ))
    }

    func test_approval_display_text_makes_controls_and_bidi_visible() {
        let raw = "echo ok\nrm -rf /\r\t\u{202E}txt"
        XCTAssertEqual(
            ApprovalCardView.sanitizedDisplayText(raw),
            "echo ok\\n\nrm -rf /\\r\\t[U+202E]txt"
        )
    }
}

private actor ImageThumbnailLoaderProbe {
    private(set) var loadCount = 0
    let thumbnail: FileImageThumbnail

    init(thumbnail: FileImageThumbnail) { self.thumbnail = thumbnail }

    func load(_ source: String) async -> FileImageThumbnail? {
        loadCount += 1
        try? await Task.sleep(nanoseconds: 50_000_000)
        return thumbnail
    }
}
