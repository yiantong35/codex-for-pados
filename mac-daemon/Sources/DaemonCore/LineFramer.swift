import Foundation

/// 从字节流按 `\n` 切出完整 NDJSON 行。
///
/// app-server 的 stdout 是换行分隔 JSON;每次 read 到的 `Data` 可能是半行、
/// 多行、或断在多字节 UTF-8 字符中间。LineFramer 缓冲不完整的尾部,
/// 只在凑齐 `\n` 时吐出整行(不含换行符)。空行(连续 `\n`)被跳过。
///
/// 纯逻辑,无 IO,非线程安全(由调用方 actor 隔离,见 AppServerConn)。
/// 在字节层切分,不解码 UTF-8,因此不会切坏跨 feed 的多字节字符。
public struct LineFramer {
    private static let newline: UInt8 = 0x0A

    /// 尚未凑齐整行的尾部字节。
    private var buffer = Data()

    public init() {}

    /// 喂入一段字节,返回本次能切出的所有完整行(按到达顺序,不含 `\n`,跳过空行)。
    public mutating func feed(_ data: Data) -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        while let nl = buffer.firstIndex(of: Self.newline) {
            let line = buffer[buffer.startIndex..<nl]
            if !line.isEmpty {
                lines.append(Data(line))
            }
            // 移除已消费的行 + 换行符
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        return lines
    }
}
