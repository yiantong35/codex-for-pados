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
    let env = try ipad.seal(Data("hello".utf8), kind: .appData)
    let out = try dev.open(env)
    #expect(out == Data("hello".utf8))
}

@Test func replayedFrameRejected() throws {
    let (ipad, dev) = try pairedSessions()
    let env = try ipad.seal(Data("x".utf8), kind: .appData)
    _ = try dev.open(env)
    #expect(throws: SecureSessionError.replayOrOutOfOrder) {
        _ = try dev.open(env)   // 同一 counter 再来 → 拒绝
    }
}

@Test func counterIncrementsMonotonically() throws {
    let (ipad, dev) = try pairedSessions()
    let e1 = try ipad.seal(Data("a".utf8), kind: .appData)
    let e2 = try ipad.seal(Data("b".utf8), kind: .appData)
    #expect(e2.counter > e1.counter)
    #expect(try dev.open(e1) == Data("a".utf8))
    #expect(try dev.open(e2) == Data("b".utf8))
}

@Test func tamperedSenderRejected() throws {
    let (ipad, dev) = try pairedSessions()
    var env = try ipad.seal(Data("hello".utf8), kind: .appData)
    env.sender = .devMachine   // 篡改方向标志 → 命中收端方向 guard
    #expect(throws: SecureSessionError.wrongSender) {
        _ = try dev.open(env)
    }
}

@Test func tamperedCounterRejected() throws {
    let (ipad, dev) = try pairedSessions()
    var env = try ipad.seal(Data("hello".utf8), kind: .appData)
    env.counter += 100   // 改大以越过 replay guard，直击 GCM 抗篡改（counter 进 nonce）
    #expect(throws: SecureSessionError.decryptFailed) {
        _ = try dev.open(env)
    }
}

@Test func tamperedCiphertextRejected() throws {
    let (ipad, dev) = try pairedSessions()
    var env = try ipad.seal(Data("hello".utf8), kind: .appData)
    env.ciphertext[env.ciphertext.startIndex] ^= 0xFF   // 翻转密文一字节 → GCM tag 校验失败
    #expect(throws: SecureSessionError.decryptFailed) {
        _ = try dev.open(env)
    }
}

/// M4 边界：空明文 seal → open 应往返得回空 Data。
@Test func emptyPlaintextRoundTrips() throws {
    let (ipad, dev) = try pairedSessions()
    let env = try ipad.seal(Data(), kind: .appData)
    #expect(try dev.open(env) == Data())
}

@Test func tamperedTagRejected() throws {
    let (ipad, dev) = try pairedSessions()
    var env = try ipad.seal(Data("hello".utf8), kind: .appData)
    env.tag[env.tag.startIndex] ^= 0xFF   // 翻转 tag 一字节 → GCM 认证失败
    #expect(throws: SecureSessionError.decryptFailed) {
        _ = try dev.open(env)
    }
}

// MARK: - ⑥a 加密帧类型标签 + AAD 认证整个 header（Task 9）

/// 已知 kind 正常 seal→open 往返，且信封携带正确 kind。
@Test func sealOpenRoundTripCarriesKind() throws {
    let (ipad, dev) = try pairedSessions()
    let env = try ipad.seal(Data("hi".utf8), kind: .appData)
    #expect(env.kind == .appData)
    #expect(try dev.open(env) == Data("hi".utf8))
}

/// 篡改 kind → 接收端以篡改值重建 AAD → tag 失配 → decryptFailed（fail-closed 第二层）。
@Test func tamperedKindFailsAEAD() throws {
    let (ipad, dev) = try pairedSessions()
    var env = try ipad.seal(Data("x".utf8), kind: .appData)
    env.kind = .secureReady                       // 中间人改 kind → AAD 失配
    #expect(throws: SecureSessionError.decryptFailed) { _ = try dev.open(env) }
}

/// 篡改任一被 AAD 认证的明文 header 字段（v/keyEpoch/sessionId）→ decryptFailed。
@Test func tamperedHeaderFieldsFailAEAD() throws {
    let (ipad, dev) = try pairedSessions()
    var e1 = try ipad.seal(Data("x".utf8), kind: .appData); e1.v = e1.v &+ 1
    #expect(throws: SecureSessionError.decryptFailed) { _ = try dev.open(e1) }
    let (ipad2, dev2) = try pairedSessions()
    var e2 = try ipad2.seal(Data("x".utf8), kind: .appData); e2.keyEpoch = e2.keyEpoch &+ 1
    #expect(throws: SecureSessionError.decryptFailed) { _ = try dev2.open(e2) }
    let (ipad3, dev3) = try pairedSessions()
    var e3 = try ipad3.seal(Data("x".utf8), kind: .appData); e3.sessionId = e3.sessionId + "!"
    #expect(throws: SecureSessionError.decryptFailed) { _ = try dev3.open(e3) }
}

// MARK: - ⑥a 未知帧类型 decode 层 fail-closed + 每种 kind 加密不变量（Task 10）

/// 未定义 kind raw value(99) 的信封 JSON 解码应抛错（decode 层 fail-closed 第一层），
/// 绝不 fall through 到任一已知分支。
@Test func unknownFrameKindRawValueRejectedAtDecode() throws {
    let json = """
    {"v":1,"sessionId":"s","keyEpoch":0,"sender":"iPad","counter":1,"kind":99,\
    "ciphertext":"AAAA","tag":"AAAAAAAAAAAAAAAAAAAAAA=="}
    """
    #expect(throws: (any Error).self) {
        _ = try SecureEnvelope(decoding: Data(json.utf8))
    }
}

/// 方向绑定/重放防护对 .secureReady 与 .appData 一致生效（不因引入 kind/AAD 而弱化）。
@Test func directionBindingAndReplayHoldForSecureReadyKind() throws {
    let (ipad, dev) = try pairedSessions()
    let env = try dev.seal(Data("ready".utf8), kind: .secureReady)   // dev 发
    #expect(env.kind == .secureReady)
    #expect(try ipad.open(env) == Data("ready".utf8))                // iPad 收，方向正确
    #expect(throws: SecureSessionError.wrongSender) { _ = try dev.open(env) }        // 同侧不能开自己发的
    #expect(throws: SecureSessionError.replayOrOutOfOrder) { _ = try ipad.open(env) } // 重放拒
}
