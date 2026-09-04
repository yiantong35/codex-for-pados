import Testing
import Foundation
import Crypto
@testable import RelayProtocol

/// chunk 帧 type 往返 + headerAAD 末字节含 2（kind 进 AAD）。
@Test func chunkFrameKindRoundTripsThroughJSON() throws {
    let env = SecureEnvelope(v: 1, sessionId: "s", keyEpoch: 0, sender: .devMachine,
                             counter: 1, kind: .chunk, ciphertext: Data([1]), tag: Data([2]))
    let back = try SecureEnvelope(decoding: try env.encoded())
    #expect(back == env)
    #expect(back.kind == .chunk)
}

@Test func headerAADIncludesChunkKindAsLastByte() {
    let aad = SecureEnvelope.headerAAD(v: 1, keyEpoch: 0, sessionId: "s",
                                       sender: .devMachine, counter: 1, kind: .chunk)
    #expect(aad.last == 2)
}

/// capabilities 往返 + 缺省 nil。
@Test func clientHelloCapabilitiesRoundTrip() throws {
    let hello = Handshake.makeClientHello(
        sessionId: "s", ipadDeviceId: "i", ipadIdentityPub: Data([1]), ipadEphemeralPub: Data([2]),
        clientNonce: Data((0..<32).map { _ in UInt8.random(in: 0...255) }),
        pairingCode: "PAIR", capabilities: ["chunk-rx-v1"])
    let back = try JSONDecoder().decode(ClientHello.self, from: JSONEncoder().encode(hello))
    #expect(back.capabilities == ["chunk-rx-v1"])
}

@Test func clientHelloWithoutCapabilitiesDecodesNil() throws {
    let hello = Handshake.makeClientHello(
        sessionId: "s", ipadDeviceId: "i", ipadIdentityPub: Data([1]), ipadEphemeralPub: Data([2]),
        clientNonce: Data([0, 1, 2, 3]), pairingCode: "PAIR")
    let back = try JSONDecoder().decode(ClientHello.self, from: JSONEncoder().encode(hello))
    #expect(back.capabilities == nil)
}

/// 加法安全：capabilities 不进 pairingProofMessage → proof 字节不变（旧端 decode 忽略未知键不破兼容）。
@Test func capabilitiesDoNotChangePairingCodeProof() throws {
    let base = Handshake.makeClientHello(
        sessionId: "s", ipadDeviceId: "i", ipadIdentityPub: Data([1]), ipadEphemeralPub: Data([2]),
        clientNonce: Data([0, 1, 2, 3]), pairingCode: "PAIR")
    let withCap = Handshake.makeClientHello(
        sessionId: "s", ipadDeviceId: "i", ipadIdentityPub: Data([1]), ipadEphemeralPub: Data([2]),
        clientNonce: Data([0, 1, 2, 3]), pairingCode: "PAIR", capabilities: ["chunk-rx-v1"])
    #expect(base.pairingCodeProof == withCap.pairingCodeProof)
}

/// 协商矩阵（协议层互通）：带/不带 capabilities 用 makeServerHello + verifyClientAuthAndFinish 都成功，
/// 且建出的 SecureSession 能 seal(.chunk) 并双方 open。
@Test func negotiationMatrixHandshakesSucceed() throws {
    let cases: [[String]?] = [["chunk-rx-v1"], nil]
    for caps in cases {
        let ipadIdentity = Curve25519.Signing.PrivateKey()
        let devIdentity = Curve25519.Signing.PrivateKey()
        let ipadEph = Curve25519.KeyAgreement.PrivateKey()
        let devEph = Curve25519.KeyAgreement.PrivateKey()
        let hello = Handshake.makeClientHello(
            sessionId: "s", ipadDeviceId: "i",
            ipadIdentityPub: ipadIdentity.publicKey.rawRepresentation,
            ipadEphemeralPub: ipadEph.publicKey.rawRepresentation,
            clientNonce: Data((0..<32).map { _ in UInt8.random(in: 0...255) }),
            pairingCode: "PAIR", capabilities: caps)
        let serverHello = try Handshake.makeServerHello(
            clientHello: hello, devDeviceId: "d", devIdentity: devIdentity,
            devEphemeralPub: devEph.publicKey.rawRepresentation,
            serverNonce: Data((0..<32).map { _ in UInt8.random(in: 0...255) }),
            keyEpoch: 0, pairingCode: "PAIR")
        let clientAuth = try Handshake.verifyServerHelloAndMakeClientAuth(
            clientHello: hello, serverHello: serverHello,
            devIdentityPub: devIdentity.publicKey.rawRepresentation, ipadIdentity: ipadIdentity)
        let dev = try Handshake.verifyClientAuthAndFinish(
            clientHello: hello, serverHello: serverHello, clientAuth: clientAuth, devEphemeral: devEph)
        let ipad = try Handshake.finishClient(
            clientHello: hello, serverHello: serverHello,
            ipadEphemeral: ipadEph, devIdentityPub: devIdentity.publicKey.rawRepresentation)
        let env = try ipad.seal(Data("x".utf8), kind: .chunk)
        #expect(try dev.open(env) == Data("x".utf8))
    }
}
