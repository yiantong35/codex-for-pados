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
