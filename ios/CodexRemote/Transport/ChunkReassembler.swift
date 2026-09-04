import Foundation

/// 重组结果（fail-closed 以 .failed 表达，调用方丢弃整个重组并按错误处理）。
enum ChunkReassemblyOutcome: Equatable {
    case incomplete
    case completed(Data)   // 累积后的原始字节（调用方按 compressed 决定解压）
    case failed(String)
}

/// 单 active buffer 的分片重组器。
/// 为什么单 buffer：同方向有序（SecureSession 计数严格递增）+ 单连接有序 + dev 按行连续发一条
/// 超大响应（无跨消息交织），因此省略 reassembly id（设计 §2.2/§2.4）。会话重建时作废。
struct ChunkReassembler: Equatable {
    /// 防御上限默认值（fail-closed），足以容纳 ~160 MiB 级大会话，同时封死无界 DoS。
    /// 三个上限均可注入：生产用默认（512 MiB 级），单测注入小值以廉价触发越限分支。
    static let defaultMaxAccumulatedBytes = 512 * 1024 * 1024   // 累积明文上限
    static let defaultMaxChunkCount: UInt32 = 4096              // 片数上限
    static let defaultMaxDecompressedBytes = 512 * 1024 * 1024  // 解压后上限（防解压炸弹）

    let maxAccumulatedBytes: Int
    let maxChunkCount: UInt32
    let maxDecompressedBytes: Int
    private(set) var accumulator = Data()
    private(set) var expectedSeq: UInt32 = 0
    private(set) var totalChunks: UInt32 = 0
    private(set) var compressed = false
    private(set) var active = false

    init(maxAccumulatedBytes: Int = ChunkReassembler.defaultMaxAccumulatedBytes,
         maxChunkCount: UInt32 = ChunkReassembler.defaultMaxChunkCount,
         maxDecompressedBytes: Int = ChunkReassembler.defaultMaxDecompressedBytes) {
        self.maxAccumulatedBytes = maxAccumulatedBytes
        self.maxChunkCount = maxChunkCount
        self.maxDecompressedBytes = maxDecompressedBytes
    }

    mutating func append(_ payload: ChunkPayload) -> ChunkReassemblyOutcome {
        // 序严格连续：乱序/缺口 → fail-closed。
        guard payload.seq == expectedSeq else {
            return .failed("chunk seq gap: expected \(expectedSeq), got \(payload.seq)")
        }
        if !active {
            // 首片（seq==0 且开始新组）。totalChunks>0 且不超片数上限。
            guard payload.totalChunks > 0, payload.totalChunks <= maxChunkCount else {
                return .failed("chunk totalChunks invalid: \(payload.totalChunks)")
            }
            active = true
            totalChunks = payload.totalChunks
            compressed = payload.compressed
        } else {
            // 续组：totalChunks 与 compressed 必须与首片一致（防串组/跨组拼接）。
            guard payload.totalChunks == totalChunks else {
                return .failed("chunk totalChunks mismatch")
            }
            guard payload.compressed == compressed else {
                return .failed("chunk compressed flag mismatch")
            }
        }
        // 字节上限：累积不超 maxAccumulatedBytes。
        guard accumulator.count + payload.data.count <= maxAccumulatedBytes else {
            return .failed("chunk buffer overflow")
        }
        accumulator.append(payload.data)
        expectedSeq += 1
        // 集齐 totalChunks 片 → 完成。
        if expectedSeq == totalChunks { return .completed(accumulator) }
        return .incomplete
    }

    mutating func reset() {
        // 保留注入的上限，作废旧组状态。
        self = ChunkReassembler(maxAccumulatedBytes: maxAccumulatedBytes,
                                maxChunkCount: maxChunkCount,
                                maxDecompressedBytes: maxDecompressedBytes)
    }
}
