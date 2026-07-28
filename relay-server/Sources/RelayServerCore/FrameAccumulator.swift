import Foundation

/// relay 面向公网的资源上限常量（决策 D3：纯加法防御，不碰零知识转发）。
///
/// 均为进程内单值——relay 是单进程服务，计数/配额用内存即可。
public enum RelayLimits {
    /// 单消息（分片累积后）字节上限：1 MiB。超限连接被关闭，内存不无界增长。
    public static let maxMessageBytes = 1 << 20
    /// 空闲（无数据往来）连接超时秒数：超时后回收连接。
    public static let idleTimeoutSeconds: Int64 = 120
    /// 全局并发连接数上限（per-IP 限流交反代承担，见 D2）。
    public static let maxTotalConnections = 2000
    /// 房间（sessionId）总数上限。
    public static let maxRooms = 500
}

/// 分片文本帧累积器：累积到 fin 才产出整消息；超上限即 overflow（调用方须关连接）。
///
/// **零知识**：只累积/产出不透明字节串，绝不解析内容。overflow 时清空缓冲，
/// 保证攻击者持续发分片也不会撑爆内存。
public struct FrameAccumulator {
    private let maxBytes: Int
    private var buffer: [UInt8] = []

    public init(maxBytes: Int) { self.maxBytes = maxBytes }

    public enum Result: Equatable {
        case accumulating          // 尚未收到 fin，继续累积
        case complete(String)      // 收到 fin，产出整条消息
        case overflow              // 累积超上限，须关连接
    }

    /// 追加一个分片。累积后超上限即清空并返回 overflow；收到 fin 则产出整消息并重置。
    public mutating func append(_ bytes: [UInt8], fin: Bool) -> Result {
        if buffer.count + bytes.count > maxBytes {
            buffer.removeAll(keepingCapacity: false)   // 超限即弃，内存不无界增长
            return .overflow
        }
        buffer.append(contentsOf: bytes)
        guard fin else { return .accumulating }
        let s = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll(keepingCapacity: false)       // 完成即重置，不串消息
        return .complete(s)
    }
}
