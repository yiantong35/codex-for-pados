import Testing
import Foundation
import Crypto
@testable import RelayProtocol

@Test func bothSidesDeriveSameDirectionalKeys() throws {
    let ipadEph = Curve25519.KeyAgreement.PrivateKey()
    let devEph  = Curve25519.KeyAgreement.PrivateKey()
    let transcript = Data("fixed-transcript".utf8)
    let ctx = KeySchedule.Context(sessionId: "sid", devDeviceId: "dev", ipadDeviceId: "ipad", keyEpoch: 0)

    // iPad 视角
    let ipadKeys = try KeySchedule.derive(
        myEphemeral: ipadEph, peerEphemeralPub: devEph.publicKey,
        transcript: transcript, context: ctx)
    // 开发机视角
    let devKeys = try KeySchedule.derive(
        myEphemeral: devEph, peerEphemeralPub: ipadEph.publicKey,
        transcript: transcript, context: ctx)

    // iPad 的“发”密钥 == 开发机的“收 iPad”密钥
    #expect(ipadKeys.sendKey(as: .iPad) == devKeys.sendKey(as: .iPad))
    #expect(ipadKeys.sendKey(as: .devMachine) == devKeys.sendKey(as: .devMachine))
    // 两个方向密钥不同
    #expect(ipadKeys.sendKey(as: .iPad) != ipadKeys.sendKey(as: .devMachine))
}

/// I2 回归：HKDF info 的域分离。两个 Context 在 `|`-join 下会拼出同一 baseInfo（碰撞），
/// 但字段语义不同。长度前缀编码必须让它们派生出不同密钥，杜绝跨字段歧义。
/// 例：sessionId="a|b",devDeviceId="c" 与 sessionId="a",devDeviceId="b|c"。
@Test func hkdfInfoIsDomainSeparated() throws {
    let ipadEph = Curve25519.KeyAgreement.PrivateKey()
    let devEph  = Curve25519.KeyAgreement.PrivateKey()
    let transcript = Data("fixed-transcript".utf8)

    let ctxA = KeySchedule.Context(sessionId: "a|b", devDeviceId: "c", ipadDeviceId: "ipad", keyEpoch: 0)
    let ctxB = KeySchedule.Context(sessionId: "a", devDeviceId: "b|c", ipadDeviceId: "ipad", keyEpoch: 0)

    let keysA = try KeySchedule.derive(
        myEphemeral: ipadEph, peerEphemeralPub: devEph.publicKey,
        transcript: transcript, context: ctxA)
    let keysB = try KeySchedule.derive(
        myEphemeral: ipadEph, peerEphemeralPub: devEph.publicKey,
        transcript: transcript, context: ctxB)

    #expect(keysA.sendKey(as: .iPad) != keysB.sendKey(as: .iPad))
    #expect(keysA.sendKey(as: .devMachine) != keysB.sendKey(as: .devMachine))
}
