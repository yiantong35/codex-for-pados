import Testing
import Foundation
import Crypto
@testable import RelayProtocol

private func pairedSessions() throws -> (ipad: SecureSession, dev: SecureSession) {
    let ipadEph = Curve25519.KeyAgreement.PrivateKey()
    let devEph  = Curve25519.KeyAgreement.PrivateKey()
    let ctx = KeySchedule.Context(sessionId: "s", devDeviceId: "d", ipadDeviceId: "i", keyEpoch: 0)
    let tr = Data("tr".utf8)
    let ik = try KeySchedule.derive(myEphemeral: ipadEph, peerEphemeralPub: devEph.publicKey, transcript: tr, context: ctx)
    let dk = try KeySchedule.derive(myEphemeral: devEph, peerEphemeralPub: ipadEph.publicKey, transcript: tr, context: ctx)
    return (SecureSession(role: .iPad, keys: ik, sessionId: "s", keyEpoch: 0),
            SecureSession(role: .devMachine, keys: dk, sessionId: "s", keyEpoch: 0))
}

@Test func encryptDecryptRoundTrip() throws {
    let (ipad, dev) = try pairedSessions()
    let env = try ipad.seal(Data("hello".utf8))
    let out = try dev.open(env)
    #expect(out == Data("hello".utf8))
}

@Test func replayedFrameRejected() throws {
    let (ipad, dev) = try pairedSessions()
    let env = try ipad.seal(Data("x".utf8))
    _ = try dev.open(env)
    #expect(throws: SecureSessionError.replayOrOutOfOrder) {
        _ = try dev.open(env)   // 同一 counter 再来 → 拒绝
    }
}

@Test func counterIncrementsMonotonically() throws {
    let (ipad, dev) = try pairedSessions()
    let e1 = try ipad.seal(Data("a".utf8))
    let e2 = try ipad.seal(Data("b".utf8))
    #expect(e2.counter > e1.counter)
    #expect(try dev.open(e1) == Data("a".utf8))
    #expect(try dev.open(e2) == Data("b".utf8))
}

@Test func tamperedSenderRejected() throws {
    let (ipad, dev) = try pairedSessions()
    var env = try ipad.seal(Data("hello".utf8))
    env.sender = .devMachine   // 篡改方向标志 → 命中收端方向 guard
    #expect(throws: SecureSessionError.wrongSender) {
        _ = try dev.open(env)
    }
}

@Test func tamperedCounterRejected() throws {
    let (ipad, dev) = try pairedSessions()
    var env = try ipad.seal(Data("hello".utf8))
    env.counter += 100   // 改大以越过 replay guard，直击 GCM 抗篡改（counter 进 nonce）
    #expect(throws: SecureSessionError.decryptFailed) {
        _ = try dev.open(env)
    }
}

@Test func tamperedCiphertextRejected() throws {
    let (ipad, dev) = try pairedSessions()
    var env = try ipad.seal(Data("hello".utf8))
    env.ciphertext[env.ciphertext.startIndex] ^= 0xFF   // 翻转密文一字节 → GCM tag 校验失败
    #expect(throws: SecureSessionError.decryptFailed) {
        _ = try dev.open(env)
    }
}

/// M4 边界：空明文 seal → open 应往返得回空 Data。
@Test func emptyPlaintextRoundTrips() throws {
    let (ipad, dev) = try pairedSessions()
    let env = try ipad.seal(Data())
    #expect(try dev.open(env) == Data())
}

@Test func tamperedTagRejected() throws {
    let (ipad, dev) = try pairedSessions()
    var env = try ipad.seal(Data("hello".utf8))
    env.tag[env.tag.startIndex] ^= 0xFF   // 翻转 tag 一字节 → GCM 认证失败
    #expect(throws: SecureSessionError.decryptFailed) {
        _ = try dev.open(env)
    }
}
