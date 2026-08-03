import XCTest
import Foundation
import Crypto
@testable import RelayProtocol
@testable import CodexRemote

/// RelayTransport 的加解密数据流单测。
///
/// 用注入的内存 mock ws 通道 + 一对已建立的 SecureSession(iPad + dev)验证 seam 数据流：
/// - send(明文) 出去的是 SecureEnvelope 密文(不含明文)，dev.open 后还原明文。
/// - dev.seal(明文) 的 env 经 mock ws 注入 → incoming() 吐出明文。
///
/// 真 ws 网络握手编排留 Task 13/真机；本测试脱离真网络覆盖加解密逻辑。
final class RelayTransportTests: XCTestCase {

    /// 造一对方向密钥建立的 iPad + dev SecureSession（对齐 RelayProtocol SecureSessionTests 的 harness）。
    private func pairedSessions() throws -> (ipad: SecureSession, dev: SecureSession) {
        let ipadEph = Curve25519.KeyAgreement.PrivateKey()
        let devEph  = Curve25519.KeyAgreement.PrivateKey()
        let ctx = KeySchedule.Context(sessionId: "s", devDeviceId: "d", ipadDeviceId: "i", keyEpoch: 0)
        let tr = Data("tr".utf8)
        let ik = try KeySchedule.derive(myEphemeral: ipadEph, peerEphemeralPub: devEph.publicKey,
                                        transcript: tr, context: ctx)
        let dk = try KeySchedule.derive(myEphemeral: devEph, peerEphemeralPub: ipadEph.publicKey,
                                        transcript: tr, context: ctx)
        return (SecureSession(role: .iPad, keys: ik, sessionId: "s", keyEpoch: 0),
                SecureSession(role: .devMachine, keys: dk, sessionId: "s", keyEpoch: 0))
    }

    // MARK: send → 密文

    func testSendEmitsCiphertextEnvelopeNotPlaintext() async throws {
        let (ipad, dev) = try pairedSessions()
        let ws = MockRelayWSChannel()
        let transport = RelayTransport(session: ipad, ws: ws)

        try await transport.send("hello")

        // mock ws 收到的一帧应是 SecureEnvelope 密文 JSON，且不含明文。
        let frames = await ws.sentFrames
        XCTAssertEqual(frames.count, 1)
        let frame = try XCTUnwrap(frames.first)
        XCTAssertFalse(frame.contains("hello"), "线上帧不得含明文")

        // dev 解出的应是原始明文。
        let env = try SecureEnvelope(decoding: Data(frame.utf8))
        let opened = try dev.open(env)
        XCTAssertEqual(String(decoding: opened, as: UTF8.self), "hello")
    }

    // MARK: incoming ← 密文解密

    func testIncomingDecryptsEnvelopeToPlaintext() async throws {
        let (ipad, dev) = try pairedSessions()
        let ws = MockRelayWSChannel()
        let transport = RelayTransport(session: ipad, ws: ws)

        // dev 侧封一条 "world"，编码成 ws text frame 注入 mock ws。
        let env = try dev.seal(Data("world".utf8))
        let frame = String(decoding: try env.encoded(), as: UTF8.self)

        var iter = transport.incoming().makeAsyncIterator()
        await ws.injectIncoming(frame)

        let line = try await iter.next()
        XCTAssertEqual(line, "world")
    }
}

/// 内存 mock ws 通道：记录发出的 text 帧，允许测试注入收到的帧。
/// receive 用「队列 + 挂起 continuation」模式：有帧立即返回，无帧则挂起等待 injectIncoming。
actor MockRelayWSChannel: RelayWSChannel {
    private(set) var sentFrames: [String] = []
    private var pending: [String] = []
    private var waiter: CheckedContinuation<String?, Never>?
    private var closed = false

    func sendText(_ text: String) async throws {
        sentFrames.append(text)
    }

    func receiveText() async throws -> String? {
        if !pending.isEmpty { return pending.removeFirst() }
        if closed { return nil }
        return await withCheckedContinuation { cont in
            self.waiter = cont
        }
    }

    func close() async {
        closed = true
        waiter?.resume(returning: nil)
        waiter = nil
    }

    /// 测试驱动：模拟服务端推来一帧（有挂起的 receive 则直接喂它，否则入队）。
    func injectIncoming(_ text: String) {
        if let w = waiter {
            waiter = nil
            w.resume(returning: text)
        } else {
            pending.append(text)
        }
    }
}
