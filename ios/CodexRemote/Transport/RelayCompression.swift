import Foundation
import Compression

enum CompressionError: Error, Equatable {
    case initializationFailed
    case processingFailed
    case outputExceedsLimit
}

/// 明文层压缩工具（iOS target）。与 dev 侧同 codec（LZFSE）、同默认参数。
enum RelayCompression {
    /// LZFSE compress；失败/无法压缩返回 nil（调用方回退原字节 + compressed=false）。
    static func compress(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        var dst = [UInt8](repeating: 0, count: data.count)
        let written = data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            compression_encode_buffer(
                &dst, dst.count,
                src.baseAddress!.assumingMemoryBound(to: UInt8.self), data.count,
                nil, COMPRESSION_LZFSE)
        }
        return written > 0 ? Data(dst[0..<written]) : nil
    }

    /// LZFSE decompress，输出硬上限 maxBytes（防解压炸弹）：超过即抛，MUST NOT 无界分配。
    ///
    /// 实现说明（本轮已验证）：本 SDK 的流式 `compression_stream_process` 无法解码
    /// `compression_encode_buffer` 生成的 LZFSE 块（`process` 首调用即返回
    /// `COMPRESSION_STATUS_ERROR`），因此改用与 `compress` 对称的一次性
    /// `compression_decode_buffer`，语义不变（同 LZFSE、输出硬上限、bomb 保护）。
    /// 一次性 decode 在 dst 太小（输出超限）时会**静默写满 dst 后返回 dst 大小**而不报溢出，
    /// 因此 dst 放大到 `maxBytes + 1`：返回 `maxBytes + 1` 即意味着解压结果 > maxBytes
    /// （解压炸弹，fail-closed 抛错）；返回 0 视为无效数据；余者即合法 ≤ maxBytes 的输出。
    static func decompress(_ data: Data, maxBytes: Int) throws -> Data {
        guard data.count > 0 else { throw CompressionError.processingFailed }
        guard maxBytes > 0 else { throw CompressionError.outputExceedsLimit }
        var dst = [UInt8](repeating: 0, count: maxBytes + 1)
        let written = dst.withUnsafeMutableBufferPointer { (dstBuf) -> Int in
            data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
                Int(compression_decode_buffer(
                    dstBuf.baseAddress!, dstBuf.count,
                    src.baseAddress!.assumingMemoryBound(to: UInt8.self), data.count,
                    nil, COMPRESSION_LZFSE))
            }
        }
        guard written <= maxBytes else { throw CompressionError.outputExceedsLimit }
        guard written > 0 else { throw CompressionError.processingFailed }
        return Data(dst[0..<written])
    }
}
