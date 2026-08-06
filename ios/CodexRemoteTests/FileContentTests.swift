import Testing
import Foundation
@testable import CodexRemote

struct FileContentTests {
    @Test func plainTextIsText() {
        let data = Data("hello world".utf8)
        #expect(FileContentDecoder.classify(bytes: data) == .text("hello world"))
    }

    @Test func emptyIsText() {
        #expect(FileContentDecoder.classify(bytes: Data()) == .text(""))
    }

    @Test func nulByteIsBinary() {
        let data = Data([0x68, 0x00, 0x69]) // h NUL i
        #expect(FileContentDecoder.classify(bytes: data) == .binary(data))
    }

    @Test func invalidUTF8IsBinary() {
        let data = Data([0xFF, 0xFE, 0x41])
        #expect(FileContentDecoder.classify(bytes: data) == .binary(data))
    }

    @Test func overLimitIsTooLarge() {
        let data = Data(repeating: 0x61, count: 512 * 1024 + 1)
        #expect(FileContentDecoder.classify(bytes: data) == .tooLarge)
    }

    @Test func imageMagicIsInspectableImage() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        #expect(FileContentDecoder.classify(bytes: png) == .image(png))
    }

    @Test func exactlyLimitIsText() {
        let data = Data(repeating: 0x61, count: 512 * 1024)
        if case .text = FileContentDecoder.classify(bytes: data) {} else {
            Issue.record("512KB 整应判为文本")
        }
    }

    @Test func decodeFromBase64Text() {
        #expect(FileContentDecoder.classify(base64: "aGk=") == .text("hi"))
    }

    @Test func decodeFromInvalidBase64IsBinary() {
        #expect(FileContentDecoder.classify(base64: "@@@notbase64@@@") == .binary(Data()))
        #expect(FileContentDecoder.classify(base64: "YQ=a") == .binary(Data()))
        #expect(FileContentDecoder.classify(base64: "YQ===") == .binary(Data()))
    }

    @Test func oversizedBase64IsRejectedBeforeContentDecode() {
        let base64 = Data(repeating: 0x61, count: FileContentDecoder.maxBytes + 1).base64EncodedString()
        #expect(FileContentDecoder.classify(base64: base64) == .tooLarge)
    }

    @Test func multibyteUTF8IsText() {
        let s = "héllo 世界"
        #expect(FileContentDecoder.classify(bytes: Data(s.utf8)) == .text(s))
    }

    @Test func textPreviewCapsPathologicalEmptyLines() {
        let text = String(repeating: "\n", count: 512 * 1024)
        let preview = FileTextPreview(text)

        #expect(preview.lines.count == FileTextPreview.maximumRenderedLines)
        #expect(preview.isTruncated)
    }

    @Test func textPreviewPreservesShortFileLines() {
        let preview = FileTextPreview("first\n\nthird\n")

        #expect(preview.lines.map(String.init) == ["first", "", "third", ""])
        #expect(!preview.isTruncated)
    }
}
