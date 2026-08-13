import Testing
import Foundation
import RelayProtocol
@testable import RelayServerCore

@Test func roomPairsTwoRolesAndForwards() {
    let rooms = RelayRooms()
    var ipadRx: [String] = [], devRx: [String] = []
    rooms.join(sessionId: "s", role: .devMachine) { devRx.append($0) }
    rooms.join(sessionId: "s", role: .iPad) { ipadRx.append($0) }
    rooms.forward(sessionId: "s", from: .iPad, frame: "e1")
    rooms.forward(sessionId: "s", from: .devMachine, frame: "e2")
    #expect(devRx == ["e1"])   // iPad 发的转给 dev
    #expect(ipadRx == ["e2"])  // dev 发的转给 iPad
}

// D4：后到同角色**不静默覆盖**——默认拒绝后到、先到保留。
// （原 secondSameRoleReplacesOlder 断言的是「后到覆盖先到」的 bug 行为，按 D4 已改为「后到被拒、先到保留」。）
@Test func secondSameRoleRejectedNotReplacing() {
    let rooms = RelayRooms()
    var first = 0, second = 0
    let r1 = rooms.join(sessionId: "s", role: .iPad) { _ in first += 1 }
    let r2 = rooms.join(sessionId: "s", role: .iPad) { _ in second += 1 }   // 应被拒
    rooms.join(sessionId: "s", role: .devMachine) { _ in }
    rooms.forward(sessionId: "s", from: .devMachine, frame: "x")
    guard case .joined = r1 else { return #expect(Bool(false)) }
    #expect(r2 == .rejectedRoleOccupied)
    #expect(first == 1 && second == 0)   // 先到收到转发，后到从未接管
}

// ⑥d：对端未加入时 forward 的帧被缓冲，对端 join 后按原序全部投递。
@Test func framesBufferedUntilPeerJoinsThenDeliveredInOrder() {
    let rooms = RelayRooms()
    var devRx: [String] = []
    // iPad 先 join 并连发 3 帧；dev 尚未加入 → 缓冲。
    rooms.join(sessionId: "s", role: .iPad) { _ in }
    rooms.forward(sessionId: "s", from: .iPad, frame: "a")
    rooms.forward(sessionId: "s", from: .iPad, frame: "b")
    rooms.forward(sessionId: "s", from: .iPad, frame: "c")
    #expect(devRx.isEmpty)                       // 对端未加入 → 尚未投递
    rooms.join(sessionId: "s", role: .devMachine) { devRx.append($0) }
    #expect(devRx == ["a", "b", "c"])            // dev 加入后按原序全投
    // 其后实时转发衔接在 flush 之后。
    rooms.forward(sessionId: "s", from: .iPad, frame: "d")
    #expect(devRx == ["a", "b", "c", "d"])
}

@Test func liveFrameCannotOvertakeBufferedFlush() {
    let rooms = RelayRooms()
    rooms.join(sessionId: "ordered", role: .iPad) { _ in }
    rooms.forward(sessionId: "ordered", from: .iPad, frame: "buffered-1")
    rooms.forward(sessionId: "ordered", from: .iPad, frame: "buffered-2")

    let firstEntered = DispatchSemaphore(value: 0)
    let releaseFirst = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    let received = LockedFrames()
    DispatchQueue.global().async {
        rooms.join(sessionId: "ordered", role: .devMachine) { frame in
            received.append(frame)
            if frame == "buffered-1" {
                firstEntered.signal()
                releaseFirst.wait()
            }
        }
        finished.signal()
    }

    #expect(firstEntered.wait(timeout: .now() + 2) == .success)
    rooms.forward(sessionId: "ordered", from: .iPad, frame: "live")
    releaseFirst.signal()
    #expect(finished.wait(timeout: .now() + 2) == .success)
    #expect(received.snapshot == ["buffered-1", "buffered-2", "live"])
}

@Test func globalBufferBudgetSpansRoomsAndIsReleased() {
    let rooms = RelayRooms(maxGlobalPendingBytes: 8)
    guard case let .joined(firstId) = rooms.join(sessionId: "one", role: .iPad, sink: { _ in }) else {
        return #expect(Bool(false))
    }
    rooms.join(sessionId: "two", role: .iPad) { _ in }
    #expect(rooms.forward(sessionId: "one", from: .iPad, frame: "12345") == .buffered)
    #expect(rooms.forward(sessionId: "two", from: .iPad, frame: "6789") == .rejectedBufferFull)
    rooms.leave(sessionId: "one", role: .iPad, connId: firstId)
    #expect(rooms.forward(sessionId: "two", from: .iPad, frame: "6789") == .buffered)
}

private final class LockedFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [String] = []
    func append(_ frame: String) { lock.lock(); frames.append(frame); lock.unlock() }
    var snapshot: [String] { lock.lock(); defer { lock.unlock() }; return frames }
}

// D4/3.3：旧 connId 的迟到/重复 leave 不得误清已在槽内的较新连接。
@Test func staleLeaveByOldConnIdDoesNotEvictNewer() {
    let rooms = RelayRooms()
    var aRx = 0, bRx = 0
    guard case let .joined(aId) = rooms.join(sessionId: "s", role: .iPad, sink: { _ in aRx += 1 }) else {
        return #expect(Bool(false))
    }
    rooms.leave(sessionId: "s", role: .iPad, connId: aId)   // A 正常离开，腾出槽
    guard case let .joined(bId) = rooms.join(sessionId: "s", role: .iPad, sink: { _ in bRx += 1 }) else {
        return #expect(Bool(false))
    }
    rooms.leave(sessionId: "s", role: .iPad, connId: aId)   // A 的迟到/重复 leave（旧 connId）——不得误清 B
    rooms.join(sessionId: "s", role: .devMachine, sink: { _ in })
    rooms.forward(sessionId: "s", from: .devMachine, frame: "y")
    #expect(bRx == 1 && aRx == 0)   // B 槽保留、收到转发；A 不受影响
    _ = bId
}

// ⑥d：待投递缓冲达帧数上限 → reject-newest（丢新、保已缓冲前缀因果序），不无界增长。
@Test func bufferRejectsNewestBeyondFrameCap() {
    let rooms = RelayRooms()
    rooms.join(sessionId: "s", role: .iPad) { _ in }
    let cap = RelayLimits.maxRoomBufferedFrames
    for i in 0..<(cap + 10) {                        // 超上限 10 帧
        rooms.forward(sessionId: "s", from: .iPad, frame: "f\(i)")
    }
    var devRx: [String] = []
    rooms.join(sessionId: "s", role: .devMachine) { devRx.append($0) }
    #expect(devRx.count == cap)                      // 只缓冲上限内的帧
    #expect(devRx.first == "f0")                     // 保前缀：最旧保留
    #expect(devRx.last == "f\(cap - 1)")             // reject-newest：超出的被丢
}

// ⑥d：字节上限先于帧数触发时也 reject-newest。
@Test func bufferRejectsBeyondByteCap() {
    let rooms = RelayRooms()
    rooms.join(sessionId: "s", role: .iPad) { _ in }
    let big = String(repeating: "x", count: 200 * 1024)   // 200 KiB/帧
    for _ in 0..<10 { rooms.forward(sessionId: "s", from: .iPad, frame: big) }  // 10×200KiB=2MiB > 512KiB
    var devRx: [String] = []
    rooms.join(sessionId: "s", role: .devMachine) { devRx.append($0) }
    // 512 KiB / 200 KiB → 至多 2 帧（第 3 帧起 200KiB 累加超 512KiB 被拒）。
    #expect(devRx.count == 2)
    #expect(devRx.allSatisfy { $0 == big })
}

@Test func oversizedOfflineFrameReturnsExplicitRejection() {
    let rooms = RelayRooms()
    rooms.join(sessionId: "s", role: .iPad) { _ in }
    let oversized = String(repeating: "x", count: RelayLimits.maxRoomBufferedBytes + 1)

    #expect(rooms.forward(sessionId: "s", from: .iPad, frame: oversized) == .rejectedBufferFull)
    #expect(rooms.forward(sessionId: "missing", from: .iPad, frame: "request") == .rejectedRoomMissing)
}

// ⑥d：缓冲后两端均离开 → 房间回收，缓冲随之释放；新 join 不再收到陈旧帧。
@Test func bufferReleasedOnRoomRecycle() {
    let rooms = RelayRooms()
    guard case let .joined(ipadId) = rooms.join(sessionId: "s", role: .iPad, sink: { _ in }) else {
        return #expect(Bool(false))
    }
    rooms.forward(sessionId: "s", from: .iPad, frame: "stale")   // 缓冲给缺席的 dev
    rooms.leave(sessionId: "s", role: .iPad, connId: ipadId)     // 两端皆空 → 房间回收
    // 全新使用同一 sessionId：dev 先 join 不应收到上一轮的 "stale"（缓冲已随房间释放）。
    var devRx: [String] = []
    rooms.join(sessionId: "s", role: .devMachine) { devRx.append($0) }
    #expect(devRx.isEmpty)
}

// ⑥d：缓冲/投递全程只持有不透明字符串，不解析内容（非 JSON 帧原样透传）。
@Test func bufferKeepsFramesOpaque() {
    let rooms = RelayRooms()
    rooms.join(sessionId: "s", role: .iPad) { _ in }
    let opaque = "not-a-json-\u{0000}-binary-ish-\u{FFFD}"
    rooms.forward(sessionId: "s", from: .iPad, frame: opaque)
    var devRx: [String] = []
    rooms.join(sessionId: "s", role: .devMachine) { devRx.append($0) }
    #expect(devRx == [opaque])   // 原样投递，未被解析/改写
}

// #2 reset-on-rejoin（仅 iPad 入向，不对称）：iPad 断线重连时，缺席期 dev 用**旧会话密钥**
// seal 的 appData 密文积在 pendingForIpad，重连的 iPad 必然解不开(新 ephemeral)→ 必须丢弃、
// 不得 flush。构造:dev 常驻 → iPad 首 join 后 leave(模拟断线,dev 槽仍在→房间保留) →
// 缺席期 dev forward 若干帧进 pendingForIpad → iPad 重新 join **不得**收到这些 stale 帧。
@Test func ipadRejoinDiscardsStalePendingForIpad() {
    let rooms = RelayRooms()
    // dev 常驻(不断线);其 sink 只用于收 peer-left 信令,不参与断言。
    rooms.join(sessionId: "s", role: .devMachine) { _ in }
    // iPad 首次 join 然后断线离开(dev 槽仍在 → 房间保留,不回收)。
    guard case let .joined(ipadId1) = rooms.join(sessionId: "s", role: .iPad, sink: { _ in }) else {
        return #expect(Bool(false))
    }
    rooms.leave(sessionId: "s", role: .iPad, connId: ipadId1)
    // 缺席期 dev 用旧会话密钥发帧 → iPad 缺席 → 进 pendingForIpad(旧密文,重连 iPad 解不开)。
    rooms.forward(sessionId: "s", from: .devMachine, frame: "stale-old-key-1")
    rooms.forward(sessionId: "s", from: .devMachine, frame: "stale-old-key-2")
    // iPad 重连 → reset-on-rejoin 应丢弃 pendingForIpad,不 flush。
    var ipadRx: [String] = []
    guard case .joined = rooms.join(sessionId: "s", role: .iPad, sink: { ipadRx.append($0) }) else {
        return #expect(Bool(false))
    }
    #expect(ipadRx.isEmpty)   // 旧密钥密文必丢:重连 iPad 不得收到 stale 帧
}

// #2 对照(防误伤 dev 入向):不对称语义只清 iPad 入向,dev 入向的 pendingForDev(iPad 发的
// 明文 ClientHello 握手引导帧,非 stale)必须保持既有 flush 行为。iPad 先 join 连发数帧
// (dev 缺席 → pendingForDev) → dev 后 join 仍须按 FIFO 原序收到全部。
@Test func devRejoinStillFlushesPendingForDevInOrder() {
    let rooms = RelayRooms()
    // iPad 在场,dev 缺席 → iPad 发的握手引导帧进 pendingForDev。
    rooms.join(sessionId: "s", role: .iPad) { _ in }
    rooms.forward(sessionId: "s", from: .iPad, frame: "hello-1")
    rooms.forward(sessionId: "s", from: .iPad, frame: "hello-2")
    rooms.forward(sessionId: "s", from: .iPad, frame: "hello-3")
    // dev 上线 → 必须按原序 flush 全部(dev 入向不受 reset-on-rejoin 影响)。
    var devRx: [String] = []
    rooms.join(sessionId: "s", role: .devMachine) { devRx.append($0) }
    #expect(devRx == ["hello-1", "hello-2", "hello-3"])
}

// 6.1/6.2：dev 离开 → 通知仍在的 iPad；离开者自己不收到。
@Test func leaveNotifiesRemainingPeer() throws {
    let rooms = RelayRooms()
    var ipadRx: [String] = []
    var devRx: [String] = []
    guard case let .joined(devId) = rooms.join(sessionId: "s", role: .devMachine, sink: { devRx.append($0) }) else {
        return #expect(Bool(false))
    }
    guard case .joined = rooms.join(sessionId: "s", role: .iPad, sink: { ipadRx.append($0) }) else {
        return #expect(Bool(false))
    }
    rooms.leave(sessionId: "s", role: .devMachine, connId: devId)
    #expect(ipadRx.count == 1)
    let sig = try RelaySignal(decoding: Data(ipadRx[0].utf8))
    #expect(sig.kind == RelaySignal.peerLeftKind && sig.sessionId == "s")
    #expect(devRx.isEmpty)   // 离开者自己不收到
}

// 6.1/6.2：对称——iPad 离开 → 通知仍在的 dev。
@Test func leaveNotifiesDevWhenIpadLeaves() throws {
    let rooms = RelayRooms()
    var devRx: [String] = []
    rooms.join(sessionId: "s", role: .devMachine) { devRx.append($0) }
    guard case let .joined(ipadId) = rooms.join(sessionId: "s", role: .iPad, sink: { _ in }) else {
        return #expect(Bool(false))
    }
    rooms.leave(sessionId: "s", role: .iPad, connId: ipadId)
    #expect(devRx.count == 1)
    #expect((try RelaySignal(decoding: Data(devRx[0].utf8))).kind == RelaySignal.peerLeftKind)
}

// 6.1/6.2：幂等——旧 connId 的迟到 leave 未清任何槽 → 不重复通知。
@Test func staleLeaveDoesNotNotify() {
    let rooms = RelayRooms()
    var devRx: [String] = []
    rooms.join(sessionId: "s", role: .devMachine) { devRx.append($0) }
    guard case let .joined(ipadId) = rooms.join(sessionId: "s", role: .iPad, sink: { _ in }) else {
        return #expect(Bool(false))
    }
    rooms.leave(sessionId: "s", role: .iPad, connId: ipadId)
    rooms.leave(sessionId: "s", role: .iPad, connId: ipadId)   // 迟到重复：槽已空
    #expect(devRx.count == 1)
}
