import Testing
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

@Test func secondSameRoleReplacesOlder() {
    let rooms = RelayRooms()
    var first = 0, second = 0
    rooms.join(sessionId: "s", role: .iPad) { _ in first += 1 }
    rooms.join(sessionId: "s", role: .iPad) { _ in second += 1 }   // 替换
    rooms.join(sessionId: "s", role: .devMachine) { _ in }
    rooms.forward(sessionId: "s", from: .devMachine, frame: "x")
    #expect(first == 0 && second == 1)
}
