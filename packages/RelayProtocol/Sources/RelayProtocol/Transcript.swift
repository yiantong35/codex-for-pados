import Foundation

/// 握手 transcript 编码：每个字段 = 4 字节大端长度前缀 + 字节。
/// 两端对同一批字段编出逐字节一致的结果，作为 HKDF salt 与签名输入。
public enum Transcript {
    public static func encode(_ fields: [Data]) -> Data {
        var out = Data()
        for f in fields {
            var len = UInt32(f.count).bigEndian
            withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
            out.append(f)
        }
        return out
    }
}
