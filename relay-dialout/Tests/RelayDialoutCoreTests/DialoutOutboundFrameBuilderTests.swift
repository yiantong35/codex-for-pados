import Testing
import Foundation
import Crypto
import RelayProtocol
@testable import RelayDialoutCore

private func makeSessionPair() throws -> (ipad: SecureSession, dev: SecureSession) {
    let ipadIdentity = Curve25519.Signing.PrivateKey()
    let devIdentity = Curve25519.Signing.PrivateKey()
    let ipadEphemeral = Curve25519.KeyAgreement.PrivateKey()
    let devEphemeral = Curve25519.KeyAgreement.PrivateKey()
    let pairingCode = "PAIR"
    let hello = Handshake.makeClientHello(
        sessionId: "session", ipadDeviceId: "ipad",
        ipadIdentityPub: ipadIdentity.publicKey.rawRepresentation,
        ipadEphemeralPub: ipadEphemeral.publicKey.rawRepresentation,
        clientNonce: Data(repeating: 7, count: 32), pairingCode: pairingCode)
    let serverHello = try Handshake.makeServerHello(
        clientHello: hello, devDeviceId: "dev", devIdentity: devIdentity,
        devEphemeralPub: devEphemeral.publicKey.rawRepresentation,
        serverNonce: Data(repeating: 8, count: 32), keyEpoch: 0, pairingCode: pairingCode)
    let auth = try Handshake.verifyServerHelloAndMakeClientAuth(
        clientHello: hello, serverHello: serverHello,
        devIdentityPub: devIdentity.publicKey.rawRepresentation, ipadIdentity: ipadIdentity)
    let dev = try Handshake.verifyClientAuthAndFinish(
        clientHello: hello, serverHello: serverHello, clientAuth: auth, devEphemeral: devEphemeral)
    let ipad = try Handshake.finishClient(
        clientHello: hello, serverHello: serverHello, ipadEphemeral: ipadEphemeral,
        devIdentityPub: devIdentity.publicKey.rawRepresentation)
    return (ipad, dev)
}

@Test func oversizedResponseBecomesCorrelatedWireSafeError() throws {
    let sessions = try makeSessionPair()
    let line = #"{"jsonrpc":"2.0","id":"request-1","result":{"data":"\#(String(repeating: "x", count: 800 * 1024))"}}"#
    let result = try DialoutOutboundFrameBuilder.build(line: line, session: sessions.dev)
    guard case .frame(let frame) = result else {
        Issue.record("oversized response should become a compact frame"); return
    }
    #expect(frame.count <= RelayWireLimits.maxMessageBytes)

    let envelope = try SecureEnvelope(decoding: frame)
    let plaintext = try sessions.ipad.open(envelope)
    let object = try #require(JSONSerialization.jsonObject(with: plaintext) as? [String: Any])
    #expect(object["id"] as? String == "request-1")
    let error = try #require(object["error"] as? [String: Any])
    #expect(error["message"] as? String == RelayWireLimits.outboundResponseTooLargeMessage)
}

@Test func oversizedNotificationIsLocallyRejected() throws {
    let sessions = try makeSessionPair()
    let line = #"{"jsonrpc":"2.0","method":"huge/event","params":{"data":"\#(String(repeating: "x", count: 800 * 1024))"}}"#
    let result = try DialoutOutboundFrameBuilder.build(line: line, session: sessions.dev)
    guard case .dropped = result else {
        Issue.record("notification should be dropped")
        return
    }
}

@Test func oversizedServerRequestIsRejectedBackToAppServer() throws {
    let sessions = try makeSessionPair()
    let line = #"{"jsonrpc":"2.0","id":"server-1","method":"huge/request","params":{"data":"\#(String(repeating: "x", count: 800 * 1024))"}}"#
    let result = try DialoutOutboundFrameBuilder.build(line: line, session: sessions.dev)
    guard case .rejectUpstream(let response) = result else {
        Issue.record("server request should be rejected upstream")
        return
    }
    let object = try #require(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
    #expect(object["id"] as? String == "server-1")
    #expect((object["error"] as? [String: Any])?["message"] as? String ==
            RelayWireLimits.outboundResponseTooLargeMessage)
}
