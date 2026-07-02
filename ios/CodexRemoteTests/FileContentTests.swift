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
        #expect(FileContentDecoder.classify(bytes: data) == .binary)
    }

    @Test func invalidUTF8IsBinary() {
        let data = Data([0xFF, 0xFE, 0x41])
        #expect(FileContentDecoder.classify(bytes: data) == .binary)
    }

    @Test func overLimitIsTooLarge() {
        let data = Data(repeating: 0x61, count: 512 * 1024 + 1)
        #expect(FileContentDecoder.classify(bytes: data) == .tooLarge)
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
        #expect(FileContentDecoder.classify(base64: "@@@notbase64@@@") == .binary)
    }

    @Test func multibyteUTF8IsText() {
        let s = "héllo 世界"
        #expect(FileContentDecoder.classify(bytes: Data(s.utf8)) == .text(s))
    }
}
