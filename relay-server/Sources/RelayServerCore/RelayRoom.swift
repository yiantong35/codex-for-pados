import Foundation
import RelayProtocol

/// relay 撮合表:按 sessionId 把两个 role(iPad/devMachine)配对,握手后纯密文双向透传。
///
/// **零知识**:frame 是不透明字符串(SecureEnvelope 密文的 ws text frame),
/// 本类型任何地方都不解析/不解密 frame 内容,只按对端 sink 转发。
///
/// **连接身份绑定(D4)**:每个角色槽绑定一个唯一 connId。后到同角色**不静默覆盖**——
/// 默认拒绝后到(先到保留);`leave` 仅当槽 connId 匹配才清,修复「较旧连接断开误清较新连接」。
///
/// 线程安全:NIO 多连接可能并发 join/forward/leave,内部用 NSLock 保护状态。
public final class RelayRooms: @unchecked Sendable {
    public typealias Sink = (String) -> Void

    /// join 结果:成功返回本连接的 connId(调用方持有,断开时按此精确 leave);
    /// 槽已被占用则拒绝后到。
    public enum JoinResult: Equatable { case joined(UUID); case rejectedRoleOccupied }

    private struct Slot { let connId: UUID; let sink: Sink }
    private struct Room { var ipad: Slot?; var dev: Slot? }

    private let lock = NSLock()
    private var rooms: [String: Room] = [:]

    public init() {}

    /// 加入角色槽。槽已被占用则**拒绝后到**(不静默覆盖),返回 `.rejectedRoleOccupied`;
    /// 成功则生成并返回 connId。
    @discardableResult
    public func join(sessionId: String, role: RelayPeer, sink: @escaping Sink) -> JoinResult {
        lock.lock(); defer { lock.unlock() }
        var room = rooms[sessionId] ?? Room()
        let connId = UUID()
        switch role {
        case .iPad:
            if room.ipad != nil { return .rejectedRoleOccupied }
            room.ipad = Slot(connId: connId, sink: sink)
        case .devMachine:
            if room.dev != nil { return .rejectedRoleOccupied }
            room.dev = Slot(connId: connId, sink: sink)
        }
        rooms[sessionId] = room
        return .joined(connId)
    }

    /// 把 frame 投给**对端** sink。对端缺失时丢弃。
    /// 不解析 frame 内容——零知识透传。
    public func forward(sessionId: String, from: RelayPeer, frame: String) {
        lock.lock()
        let target: Sink?
        switch from {
        case .iPad: target = rooms[sessionId]?.dev?.sink       // iPad 发的投给 dev
        case .devMachine: target = rooms[sessionId]?.ipad?.sink // dev 发的投给 iPad
        }
        lock.unlock()
        // TODO(探路阶段): 对端未连接时直接丢弃,不排队;后续可按需加缓冲。
        target?(frame)
    }

    /// 清除某 role 的槽(连接断开时用)。
    /// **仅当槽 connId 与传入一致才清**(修复「较旧连接断开误清较新连接」)。两端都空则回收房间。
    public func leave(sessionId: String, role: RelayPeer, connId: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard var room = rooms[sessionId] else { return }
        switch role {
        case .iPad: if room.ipad?.connId == connId { room.ipad = nil }
        case .devMachine: if room.dev?.connId == connId { room.dev = nil }
        }
        if room.ipad == nil && room.dev == nil {
            rooms[sessionId] = nil
        } else {
            rooms[sessionId] = room
        }
    }
}
