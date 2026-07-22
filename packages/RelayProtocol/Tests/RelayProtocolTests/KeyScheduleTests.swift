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
