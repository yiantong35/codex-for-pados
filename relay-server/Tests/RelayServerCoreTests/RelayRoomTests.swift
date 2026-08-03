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
