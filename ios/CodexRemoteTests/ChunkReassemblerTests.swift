import XCTest
import Foundation
@testable import CodexRemote

final class ChunkReassemblerTests: XCTestCase {
    private func payloads(from data: Data, count: Int) -> [ChunkPayload] {
        let per = data.count / count
        var result: [ChunkPayload] = []
        for i in 0..<count {
            let start = i * per
            let end = i == count - 1 ? data.count : start + per
            result.append(ChunkPayload(seq: UInt32(i), totalChunks: UInt32(count),
                                       compressed: false, data: Data(data[start..<end])))
        }
        return result
    }

    func testReassemblesChunksInSequence() throws {
        let raw = Data((0..<4096).map { UInt8($0 % 251) })
        let chunks = payloads(from: raw, count: 4)
        var reassembler = ChunkReassembler()
        for (i, chunk) in chunks.enumerated() {
            let out = reassembler.append(chunk)
            if i < 3 { XCTAssertEqual(out, .incomplete) }
            else if case .completed(let got) = out { XCTAssertEqual(got, raw) }
            else { XCTFail("expected completed at last chunk") }
        }
    }

    func testSeqGapDetectedFails() {
        let raw = Data(repeating: 0x11, count: 200)
        let chunks = payloads(from: raw, count: 2)
        var reassembler = ChunkReassembler()
        XCTAssertEqual(reassembler.append(chunks[0]), .incomplete)   // expectedSeq 此时为 1
        // 跳过 seq=1，直接给 seq=2 → 缺口，fail-closed。
        let gap = ChunkPayload(seq: 2, totalChunks: 2, compressed: false, data: Data([0xFF]))
        XCTAssertTrue(reassembler.append(gap).isFailed)
    }

    func testTooManyChunksFails() {
        var reassembler = ChunkReassembler(maxChunkCount: 5)
        let bad = ChunkPayload(seq: 0, totalChunks: 6, compressed: false, data: Data([1]))
        XCTAssertTrue(reassembler.append(bad).isFailed)
    }

    func testByteCapFails() {
        // 注入远小于默认值（512 MiB）的累积上限，廉价触发累积越限分支。
        var reassembler = ChunkReassembler(maxAccumulatedBytes: 10)
        XCTAssertEqual(
            reassembler.append(ChunkPayload(seq: 0, totalChunks: 2, compressed: false, data: Data([1, 2, 3, 4, 5, 6]))),
            .incomplete)
        XCTAssertTrue(
            reassembler.append(ChunkPayload(seq: 1, totalChunks: 2, compressed: false, data: Data([7, 8, 9, 10, 11]))).isFailed)
    }

    func testNewSeqZeroAfterIncompleteFails() {
        var reassembler = ChunkReassembler()
        let first = ChunkPayload(seq: 0, totalChunks: 3, compressed: false, data: Data([1, 2, 3]))
        XCTAssertEqual(reassembler.append(first), .incomplete)
        // 前一组未完成又见 seq=0 → 视为不完整重启，fail-closed。
        let again = ChunkPayload(seq: 0, totalChunks: 2, compressed: false, data: Data([9]))
        XCTAssertTrue(reassembler.append(again).isFailed)
    }

    func testResetClearsState() {
        var reassembler = ChunkReassembler()
        _ = reassembler.append(ChunkPayload(seq: 0, totalChunks: 2, compressed: false, data: Data([1])))
        reassembler.reset()
        XCTAssertEqual(reassembler.append(ChunkPayload(seq: 0, totalChunks: 1, compressed: false, data: Data([9]))),
                       .completed(Data([9])))
    }

    func testCompressDecompressRoundTrip() throws {
        let raw = Data(repeating: 0x41, count: 2 * 1024 * 1024)
        guard let packed = RelayCompression.compress(raw) else { return XCTFail("compress failed") }
        XCTAssertLessThan(packed.count, raw.count)
        let back = try RelayCompression.decompress(packed, maxBytes: 4 * 1024 * 1024)
        XCTAssertEqual(back, raw)
    }

    func testDecompressBombFailsClosed() throws {
        let raw = Data(repeating: 0, count: 8 * 1024 * 1024)   // 高压缩比 → 解压巨大
        guard let packed = RelayCompression.compress(raw) else { return }
        XCTAssertThrowsError(try RelayCompression.decompress(packed, maxBytes: 1 * 1024 * 1024)) { err in
            XCTAssertEqual(err as? CompressionError, .outputExceedsLimit)
        }
    }
}

extension ChunkReassemblyOutcome {
    var isFailed: Bool { if case .failed = self { return true }; return false }
}
