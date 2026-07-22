import Foundation
import RelayProtocol

/// relay 撮合表:按 sessionId 把两个 role(iPad/devMachine)配对,握手后纯密文双向透传。
///
/// **零知识**:frame 是不透明字符串(SecureEnvelope 密文的 ws text frame),
/// 本类型任何地方都不解析/不解密 frame 内容,只按对端 sink 转发。
///
/// 线程安全:NIO 多连接可能并发 join/forward/leave,内部用 NSLock 保护状态。
public final class RelayRooms: @unchecked Sendable {
    public typealias Sink = (String) -> Void

    private struct Room {
        var ipad: Sink?
        var dev: Sink?
    }

    private let lock = NSLock()
    private var rooms: [String: Room] = [:]

    public init() {}

    /// 存回调。同 role 覆盖旧的(后到的连接替换先到的)。
    public func join(sessionId: String, role: RelayPeer, sink: @escaping Sink) {
        lock.lock(); defer { lock.unlock() }
        var room = rooms[sessionId] ?? Room()
        switch role {
        case .iPad: room.ipad = sink
        case .devMachine: room.dev = sink
        }
        rooms[sessionId] = room
    }

    /// 把 frame 投给**对端** sink。对端缺失时丢弃。
    /// 不解析 frame 内容——零知识透传。
    public func forward(sessionId: String, from: RelayPeer, frame: String) {
        lock.lock()
        let target: Sink?
        switch from {
        case .iPad: target = rooms[sessionId]?.dev       // iPad 发的投给 dev
        case .devMachine: target = rooms[sessionId]?.ipad // dev 发的投给 iPad
        }
        lock.unlock()
        // TODO(探路阶段): 对端未连接时直接丢弃,不排队;后续可按需加缓冲。
        target?(frame)
    }

    /// 清除某 role 的 sink(连接断开时用)。两端都空则回收房间。
    public func leave(sessionId: String, role: RelayPeer) {
        lock.lock(); defer { lock.unlock() }
        guard var room = rooms[sessionId] else { return }
        switch role {
        case .iPad: room.ipad = nil
        case .devMachine: room.dev = nil
        }
        if room.ipad == nil && room.dev == nil {
            rooms[sessionId] = nil
        } else {
            rooms[sessionId] = room
        }
    }
}
