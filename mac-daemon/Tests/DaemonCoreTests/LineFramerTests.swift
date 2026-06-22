import XCTest
import Foundation
@testable import DaemonCore

/// LineFramer:从 stdout 字节流按 `\n` 切出完整 NDJSON 行(不含换行符),半行留缓冲。
final class LineFramerTests: XCTestCase {

    private func str(_ d: Data) -> String { String(decoding: d, as: UTF8.self) }
    private func strs(_ ds: [Data]) -> [String] { ds.map(str) }

    func testSingleCompleteLine() {
        var f = LineFramer()
        let out = f.feed(Data("{\"a\":1}\n".utf8))
        XCTAssertEqual(strs(out), ["{\"a\":1}"])
    }

    func testHalfLineBufferedAcrossFeeds() {
        var f = LineFramer()
        XCTAssertEqual(strs(f.feed(Data("{\"a\"".utf8))), [])          // 半行,无输出
        XCTAssertEqual(strs(f.feed(Data(":1}\n".utf8))), ["{\"a\":1}"]) // 补齐后切出
    }

    func testMultipleLinesInOneFeed() {
        var f = LineFramer()
        let out = f.feed(Data("a\nb\nc\n".utf8))
        XCTAssertEqual(strs(out), ["a", "b", "c"])
    }

    func testTrailingPartialAfterCompleteLines() {
        var f = LineFramer()
        let out = f.feed(Data("a\nb\npar".utf8))
        XCTAssertEqual(strs(out), ["a", "b"])             // par 留缓冲
        XCTAssertEqual(strs(f.feed(Data("tial\n".utf8))), ["partial"])
    }

    func testEmptyLinesSkipped() {
        var f = LineFramer()
        let out = f.feed(Data("a\n\n\nb\n".utf8))
        XCTAssertEqual(strs(out), ["a", "b"])             // 空行跳过
    }

    func testUTF8MultibyteNotCorrupted() {
        var f = LineFramer()
        // "你好" 跨两次 feed 到达,中间断在多字节字符里
        let full = Array("你好世界".utf8)
        let mid = full.count / 2
        XCTAssertEqual(strs(f.feed(Data(full[0..<mid]))), [])
        var rest = Data(full[mid...]); rest.append(0x0A)
        XCTAssertEqual(strs(f.feed(rest)), ["你好世界"])
    }

    func testLargeLine() {
        var f = LineFramer()
        let big = String(repeating: "x", count: 200_000)
        let out = f.feed(Data((big + "\n").utf8))
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.count, 200_000)
    }

    func testNoNewlineYieldsNothing() {
        var f = LineFramer()
        XCTAssertEqual(strs(f.feed(Data("no newline yet".utf8))), [])
    }
}
