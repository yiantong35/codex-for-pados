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
    private struct Room {
        var ipad: Slot?
        var dev: Slot?
        // ⑥d：缺席对端方向的有界 FIFO（不透明密文帧）+ 字节计数。
        // 零知识：只存不解析。达上限 reject-newest（见 forward）。
        var pendingForIpad: [String] = []   // dev 发、iPad 缺席时缓冲
        var pendingForDev: [String] = []    // iPad 发、dev 缺席时缓冲
        var pendingForIpadBytes = 0
        var pendingForDevBytes = 0
    }

    private let lock = NSLock()
    private var rooms: [String: Room] = [:]

    public init() {}

    /// 加入角色槽。槽已被占用则**拒绝后到**(不静默覆盖),返回 `.rejectedRoleOccupied`;
    /// 成功则生成并返回 connId。
    ///
    /// ⑥d：加入成功后按 FIFO 原序 flush 本方向缓冲——**lock-snapshot-then-drain**：
    /// 持锁内快照并清空该方向缓冲，**显式 unlock**（非 defer），再在锁外按序逐帧投递。
    /// 避免持锁调 sink（重入/长临界区）与 flush 期新 live 帧插到缓冲帧之前破坏顺序。
    @discardableResult
    public func join(sessionId: String, role: RelayPeer, sink: @escaping Sink) -> JoinResult {
        lock.lock()
        var room = rooms[sessionId] ?? Room()
        let connId = UUID()
        var flush: [String] = []
        switch role {
        case .iPad:
            if room.ipad != nil { lock.unlock(); return .rejectedRoleOccupied }
            room.ipad = Slot(connId: connId, sink: sink)
            flush = room.pendingForIpad                       // 快照本方向缓冲
            room.pendingForIpad = []; room.pendingForIpadBytes = 0   // 清空
        case .devMachine:
            if room.dev != nil { lock.unlock(); return .rejectedRoleOccupied }
            room.dev = Slot(connId: connId, sink: sink)
            flush = room.pendingForDev
            room.pendingForDev = []; room.pendingForDevBytes = 0
        }
        rooms[sessionId] = room
        lock.unlock()                                          // 显式解锁——投递前就解锁
        for f in flush { sink(f) }                             // 锁外按序投递（避免持锁调 sink 重入/长临界区）
        return .joined(connId)
    }

    /// 把 frame 投给**对端** sink；对端缺席时入有界 FIFO 缓冲（对端 join 后按序 flush）。
    /// 达帧数或字节上限 → reject-newest（O(1) 拒新，保已缓冲前缀因果序）。
    /// 不解析 frame 内容——零知识透传。
    public func forward(sessionId: String, from: RelayPeer, frame: String) {
        lock.lock()
        guard var room = rooms[sessionId] else { lock.unlock(); return }
        let target: Sink?
        switch from {
        case .iPad:       target = room.dev?.sink       // iPad 发的投给 dev
        case .devMachine: target = room.ipad?.sink      // dev 发的投给 iPad
        }
        if let target {
            lock.unlock()
            target(frame)        // 对端在场 → 锁外实时投递（原实时路径不变）
            return
        }
        // 对端缺席 → 有界缓冲（reject-newest）。
        let bytes = frame.utf8.count
        switch from {
        case .iPad:   // 投给 dev，dev 缺席 → 存 pendingForDev
            if room.pendingForDev.count < RelayLimits.maxRoomBufferedFrames &&
               room.pendingForDevBytes + bytes <= RelayLimits.maxRoomBufferedBytes {
                room.pendingForDev.append(frame)
                room.pendingForDevBytes += bytes
            }   // else: 达上限，丢弃新帧（reject-newest）
        case .devMachine:   // 投给 iPad，iPad 缺席 → 存 pendingForIpad
            if room.pendingForIpad.count < RelayLimits.maxRoomBufferedFrames &&
               room.pendingForIpadBytes + bytes <= RelayLimits.maxRoomBufferedBytes {
                room.pendingForIpad.append(frame)
                room.pendingForIpadBytes += bytes
            }
        }
        rooms[sessionId] = room
        lock.unlock()
    }

    /// 清除某 role 的槽(连接断开时用)。
    /// **仅当槽 connId 与传入一致才清**(修复「较旧连接断开误清较新连接」)。两端都空则回收房间。
    ///
    /// 6.1/6.2：某槽被实际清除(connId 匹配)且另一槽仍在时，向仍在的对端下发
    /// `RelaySignal(peer-left)` 连接层信令(零知识:仅 kind+sessionId,不含任何会话内容)。
    /// **锁纪律**:锁内只判定并记录 `notifySink`,**解锁后**再回调 sink(sink 内部会 hop 到
    /// eventLoop,不能在持锁时同步重入 `rooms`)。旧 connId 迟到 leave 未清槽 → 不通知(幂等)。
    public func leave(sessionId: String, role: RelayPeer, connId: UUID) {
        lock.lock()
        var notifySink: Sink? = nil
        if var room = rooms[sessionId] {
            var removed = false
            switch role {
            case .iPad: if room.ipad?.connId == connId { room.ipad = nil; removed = true }
            case .devMachine: if room.dev?.connId == connId { room.dev = nil; removed = true }
            }
            if room.ipad == nil && room.dev == nil {
                rooms[sessionId] = nil
            } else {
                rooms[sessionId] = room
                if removed { notifySink = room.ipad?.sink ?? room.dev?.sink }   // 仍在的对端
            }
        }
        lock.unlock()
        if let sink = notifySink,
           let json = try? String(decoding: RelaySignal(kind: RelaySignal.peerLeftKind,
                                                         sessionId: sessionId).encoded(), as: UTF8.self) {
            sink(json)
        }
    }
}
