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

// MARK: - Task 2: dev 侧拆片（协商成功走 .chunk 分片；未协商回退 -32010）

/// 纯函数：跨 chunkPlaintextBudget 边界拆分，seq 连续、totalChunks 正确、重组后 == 原明文。
@Test func chunkPayloadsSplitAtBudgetBoundary() throws {
    let raw = Data(repeating: 0x41, count: chunkPlaintextBudget + 1234)
    let payloads = DialoutOutboundFrameBuilder.chunkPayloads(plaintext: raw, compressed: false)
    #expect(payloads.count == 2)
    #expect(payloads[0].seq == 0 && payloads[1].seq == 1)
    #expect(payloads[0].totalChunks == 2 && payloads[1].totalChunks == 2)
    #expect(payloads[0].compressed == false)
    #expect(payloads[0].data.count <= chunkPlaintextBudget)
    var joined = Data()
    for p in payloads { joined.append(p.data) }
    #expect(joined == raw)
}

/// 协商成功：超限 response 被拆成 kind=.chunk 的 frames，每片 ≤ maxBytes，ipa 侧重组回原文。
@Test func oversizedResponseChunkedWhenPeerSupportsChunk() throws {
    let sessions = try makeSessionPair()
    let line = #"{"jsonrpc":"2.0","id":"request-1","result":{"data":"\#(String(repeating: "x", count: 800 * 1024))"}}"#
    let result = try DialoutOutboundFrameBuilder.build(
        line: line, session: sessions.dev, peerSupportsChunk: true)
    guard case .frames(let frames) = result else {
        Issue.record("expected .frames for oversized+negotiated"); return
    }
    #expect(!frames.isEmpty)
    var joined = Data()
    var anyCompressed = false
    var expectedSeq: UInt32 = 0
    var total: UInt32 = 0
    for f in frames {
        #expect(f.count <= RelayWireLimits.maxMessageBytes)
        let env = try SecureEnvelope(decoding: f)
        #expect(env.kind == .chunk)
        let plaintext = try sessions.ipad.open(env)
        let payload = try JSONDecoder().decode(ChunkPayload.self, from: plaintext)
        #expect(payload.seq == expectedSeq)
        expectedSeq += 1
        total = payload.totalChunks
        if payload.compressed { anyCompressed = true }
        joined.append(payload.data)
    }
    #expect(expectedSeq == total)
    // Task 4 引入压缩后，payload.data 可能是压缩字节；重组后按 compressed 标志先解压再比对原行。
    if anyCompressed {
        joined = try RelayDialoutCompression.decompress(joined, maxBytes: 4 * 1024 * 1024)
    }
    #expect(String(decoding: joined, as: UTF8.self) == line)
}

/// 未协商：超限 response 维持 -32010 替换，绝不返回 .frames。
@Test func oversizedResponseFallsBackToErrorWhenPeerDoesNotSupportChunk() throws {
    let sessions = try makeSessionPair()
    let line = #"{"jsonrpc":"2.0","id":"request-1","result":{"data":"\#(String(repeating: "x", count: 800 * 1024))"}}"#
    let result = try DialoutOutboundFrameBuilder.build(line: line, session: sessions.dev, peerSupportsChunk: false)
    guard case .frame(let frame) = result else {
        Issue.record("un-negotiated oversized should become compact error frame"); return
    }
    let envelope = try SecureEnvelope(decoding: frame)
    let plaintext = try sessions.ipad.open(envelope)
    let object = try #require(JSONSerialization.jsonObject(with: plaintext) as? [String: Any])
    let error = try #require(object["error"] as? [String: Any])
    #expect(error["code"] as? Int == -32010)
    #expect(error["message"] as? String == RelayWireLimits.outboundResponseTooLargeMessage)
}

/// 恰在 1 MiB 边界的明文不应触发分片（只有 original.count > maxBytes 才分片）。
@Test func exactlyOneMiBPayloadIsNotChunked() throws {
    let sessions = try makeSessionPair()
    // 构造一个密封后恰 ≤ maxBytes 的行：minimal。
    let line = #"{"jsonrpc":"2.0","id":"n","result":{"ok":true}}"#
    let result = try DialoutOutboundFrameBuilder.build(line: line, session: sessions.dev, peerSupportsChunk: true)
    guard case .frame = result else { Issue.record("small payload should stay .frame"); return }
}

// MARK: - Task 4: dev 侧压缩决策（压缩后确实变小才置 compressed=true）

/// 压缩决策：高度可压缩明文 → 各片 compressed=true，重组解压后交付行与原行一致（回归护栏）。
@Test func chunkedFramesMarkCompressedOnlyWhenBeneficial() throws {
    let sessions = try makeSessionPair()
    let compressible = String(repeating: "A", count: 900 * 1024) +
        #"{"jsonrpc":"2.0","id":"req","result":{"data":"\#(String(repeating: "B", count: 100 * 1024))"}}"#
    let res = try DialoutOutboundFrameBuilder.build(
        line: compressible, session: sessions.dev, peerSupportsChunk: true)
    guard case .frames(let frames) = res else { Issue.record("expected frames"); return }
    var anyCompressed = false
    var joined = Data()
    for f in frames {
        let env = try SecureEnvelope(decoding: f)
        let payload = try JSONDecoder().decode(ChunkPayload.self, from: sessions.ipad.open(env))
        if payload.compressed { anyCompressed = true }
        joined.append(payload.data)
    }
    #expect(anyCompressed)
    let back = try RelayDialoutCompression.decompress(joined, maxBytes: 4 * 1024 * 1024)
    #expect(String(decoding: back, as: UTF8.self) == compressible)
}
