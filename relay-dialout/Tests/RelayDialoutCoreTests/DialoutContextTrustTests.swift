import Testing
import Foundation
import Crypto
import RelayProtocol
@testable import RelayDialoutCore

/// 驱动 DialoutContext 走完一次真实的四消息握手（在内存中模拟 iPad 侧），
/// 验证 Task 2.2/2.3：首次配对自动记信任 + 稳定 sessionId 生成/复用 + 加密回传 SecureReady。
private struct DialoutTrustHarness {
    let devDir: URL
    let trustDir: URL
    let devKeyStore: DevKeyStore
    let devDeviceId = "dev-1"
    let pairingCode = "PAIR-OK"
    let expiresAt = Int64(Date().timeIntervalSince1970) + 600

    // iPad 侧身份/交换密钥（模拟单台 iPad，跨多次配对保持不变以验证 stableSessionId 复用）。
    let ipadIdentity: Curve25519.Signing.PrivateKey
    let ipadEphemeral: Curve25519.KeyAgreement.PrivateKey

    init(ipadIdentity: Curve25519.Signing.PrivateKey = Curve25519.Signing.PrivateKey(),
         ipadEphemeral: Curve25519.KeyAgreement.PrivateKey = Curve25519.KeyAgreement.PrivateKey()) throws {
        self.devDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        self.trustDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        self.devKeyStore = try DevKeyStore(dir: devDir)
        self.ipadIdentity = ipadIdentity
        self.ipadEphemeral = ipadEphemeral
    }

    var ipadPubB64: String { ipadIdentity.publicKey.rawRepresentation.base64EncodedString() }

    /// 用给定的 TrustStore 造一个 DialoutContext 并走完握手；返回加密回传帧 + iPad 侧 session。
    /// context 注入的 sessionId 与 ClientHello 房间号一致（与 main.swift 实际行为对齐）。
    func runHandshake(trust: TrustStore, sessionId: String) throws -> (readyFrame: Data, ipadSession: SecureSession) {
        let context = DialoutContext(keyStore: devKeyStore, devDeviceId: devDeviceId,
                                     sessionId: sessionId,
                                     pairingCode: pairingCode, expiresAt: expiresAt, trust: trust)
        // 1. iPad → ClientHello
        let clientNonce = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let hello = Handshake.makeClientHello(
            sessionId: sessionId, ipadDeviceId: "ipad-1",
            ipadIdentityPub: ipadIdentity.publicKey.rawRepresentation,
            ipadEphemeralPub: ipadEphemeral.publicKey.rawRepresentation,
            clientNonce: clientNonce, pairingCode: pairingCode)
        // 2. dev 处理 ClientHello → ServerHello
        let serverHelloData = try context.handleClientHello(JSONEncoder().encode(hello))
        let serverHello = try JSONDecoder().decode(ServerHello.self, from: serverHelloData)
        // 3. iPad 验 devSignature 并造 ClientAuth + 建 iPad 侧 session
        let clientAuth = try Handshake.verifyServerHelloAndMakeClientAuth(
            clientHello: hello, serverHello: serverHello,
            devIdentityPub: devKeyStore.identityPublicKeyRaw, ipadIdentity: ipadIdentity)
        let ipadSession = try Handshake.finishClient(
            clientHello: hello, serverHello: serverHello,
            ipadEphemeral: ipadEphemeral, devIdentityPub: devKeyStore.identityPublicKeyRaw)
        // 4. dev 验 ClientAuth → 记信任 + 加密回传 SecureReady
        let readyFrame = try context.handleClientAuth(JSONEncoder().encode(clientAuth))
        return (readyFrame, ipadSession)
    }
}

@Test func firstPairingRecordsTrustWithStableSessionId() throws {
    let h = try DialoutTrustHarness()
    let trust = try TrustStore(dir: h.trustDir)
    _ = try h.runHandshake(trust: trust, sessionId: "room-1")

    let rec = trust.record(forPubB64: h.ipadPubB64)
    #expect(rec != nil)
    let stable = rec?.stableSessionId ?? ""
    #expect(!stable.isEmpty)
}

@Test func handleClientAuthReturnsEncryptedSecureReady() throws {
    let h = try DialoutTrustHarness()
    let trust = try TrustStore(dir: h.trustDir)
    let (frame, ipadSession) = try h.runHandshake(trust: trust, sessionId: "room-1")

    // 回传帧必须是加密 SecureEnvelope（不明文过 relay），iPad 侧用自己 session 解开。
    let env = try SecureEnvelope(decoding: frame)
    let plaintext = try ipadSession.open(env)
    let ready = try JSONDecoder().decode(SecureReady.self, from: plaintext)

    let stable = trust.record(forPubB64: h.ipadPubB64)?.stableSessionId
    #expect(ready.stableSessionId == stable)
    #expect(ready.sessionId == "room-1")
    #expect(ready.devDeviceId == h.devDeviceId)
}

@Test func handleClientAuthRejectsReplayOfSameFrame() throws {
    // relay 是不可信中转：若把已握手成功那一帧 ClientAuth 明文原样重放进来，
    // handleClientAuth 必须拒绝，不能重新验签/重发 SecureReady（会话已建立，一次性口令早该失效）。
    let h = try DialoutTrustHarness()
    let trust = try TrustStore(dir: h.trustDir)
    let context = DialoutContext(keyStore: h.devKeyStore, devDeviceId: h.devDeviceId,
                                 sessionId: "room-1", pairingCode: h.pairingCode,
                                 expiresAt: h.expiresAt, trust: trust)
    let clientNonce = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
    let hello = Handshake.makeClientHello(
        sessionId: "room-1", ipadDeviceId: "ipad-1",
        ipadIdentityPub: h.ipadIdentity.publicKey.rawRepresentation,
        ipadEphemeralPub: h.ipadEphemeral.publicKey.rawRepresentation,
        clientNonce: clientNonce, pairingCode: h.pairingCode)
    let serverHelloData = try context.handleClientHello(JSONEncoder().encode(hello))
    let serverHello = try JSONDecoder().decode(ServerHello.self, from: serverHelloData)
    let clientAuth = try Handshake.verifyServerHelloAndMakeClientAuth(
        clientHello: hello, serverHello: serverHello,
        devIdentityPub: h.devKeyStore.identityPublicKeyRaw, ipadIdentity: h.ipadIdentity)
    let clientAuthData = try JSONEncoder().encode(clientAuth)

    _ = try context.handleClientAuth(clientAuthData)   // 首次：正常建通道，pairingConsumed 置 true

    #expect(throws: DialoutHandshakeError.pairingAlreadyUsed) {
        _ = try context.handleClientAuth(clientAuthData)   // relay 重放同一帧：必须拒绝
    }
}

@Test func repeatedPairingReusesSameStableSessionId() throws {
    let h = try DialoutTrustHarness()
    // 第一次配对：新 TrustStore。
    let trust1 = try TrustStore(dir: h.trustDir)
    _ = try h.runHandshake(trust: trust1, sessionId: "room-1")
    let firstStable = trust1.record(forPubB64: h.ipadPubB64)?.stableSessionId
    #expect(!(firstStable?.isEmpty ?? true))

    // 同一 iPad 再次配对：从磁盘重载 TrustStore + 新 DialoutContext，应复用同一 stableSessionId。
    let trust2 = try TrustStore(dir: h.trustDir)
    let (frame, ipadSession) = try h.runHandshake(trust: trust2, sessionId: "room-2")
    let secondStable = trust2.record(forPubB64: h.ipadPubB64)?.stableSessionId
    #expect(secondStable == firstStable)
    #expect(trust2.all().count == 1)   // 幂等，不新增记录

    // 回传帧里的 stableSessionId 也应是复用后的稳定值。
    let ready = try JSONDecoder().decode(
        SecureReady.self, from: try ipadSession.open(try SecureEnvelope(decoding: frame)))
    #expect(ready.stableSessionId == firstStable)
}

// MARK: - Batch C1：受信任复连 / 防降级 / 重握手

/// 用给定 iPad 身份构造 ClientHello；emptyProof=true 时清空 pairingCodeProof（模拟受信任复连免口令）。
private func buildHello(sessionId: String,
                        ipadIdentity: Curve25519.Signing.PrivateKey,
                        ipadEphemeral: Curve25519.KeyAgreement.PrivateKey,
                        pairingCode: String,
                        emptyProof: Bool) -> ClientHello {
    var hello = Handshake.makeClientHello(
        sessionId: sessionId, ipadDeviceId: "ipad-1",
        ipadIdentityPub: ipadIdentity.publicKey.rawRepresentation,
        ipadEphemeralPub: ipadEphemeral.publicKey.rawRepresentation,
        clientNonce: Data((0..<32).map { _ in UInt8.random(in: 0...255) }),
        pairingCode: pairingCode)
    if emptyProof { hello.pairingCodeProof = Data() }
    return hello
}

/// 在给定 context 上驱动步骤 2~4（dev handleClientHello → iPad 验签造 ClientAuth → dev handleClientAuth）。
private func driveHandshake(context: DialoutContext, hello: ClientHello,
                            ipadIdentity: Curve25519.Signing.PrivateKey,
                            ipadEphemeral: Curve25519.KeyAgreement.PrivateKey,
                            devIdentityPubRaw: Data) throws -> (readyFrame: Data, ipadSession: SecureSession) {
    let shData = try context.handleClientHello(JSONEncoder().encode(hello))
    let sh = try JSONDecoder().decode(ServerHello.self, from: shData)
    let auth = try Handshake.verifyServerHelloAndMakeClientAuth(
        clientHello: hello, serverHello: sh, devIdentityPub: devIdentityPubRaw, ipadIdentity: ipadIdentity)
    let ipadSession = try Handshake.finishClient(
        clientHello: hello, serverHello: sh, ipadEphemeral: ipadEphemeral, devIdentityPub: devIdentityPubRaw)
    let frame = try context.handleClientAuth(JSONEncoder().encode(auth))
    return (frame, ipadSession)
}

/// 受信任 iPad 空 proof → handleClientHello 成功产 ServerHello，且不被 expiresAt（此处已过期）挡。
/// 证明受信任复连既免 proof、又不受一次性口令的过期/消费约束。
@Test func trustedEmptyProofHandleClientHelloSucceedsIgnoringExpiry() throws {
    let h = try DialoutTrustHarness()
    let trust = try TrustStore(dir: h.trustDir)
    try trust.trust(ipadPubB64: h.ipadPubB64, stableSessionId: "stable-preset", label: nil)  // 预置信任
    // pairingCode 已过期：受信任复连不该被过期挡。
    let context = DialoutContext(keyStore: h.devKeyStore, devDeviceId: h.devDeviceId,
                                 sessionId: "room-1", pairingCode: h.pairingCode,
                                 expiresAt: Int64(Date().timeIntervalSince1970) - 10, trust: trust)
    let hello = buildHello(sessionId: "room-1", ipadIdentity: h.ipadIdentity,
                           ipadEphemeral: h.ipadEphemeral, pairingCode: "unused", emptyProof: true)
    let shData = try context.handleClientHello(JSONEncoder().encode(hello))   // 不抛
    let sh = try JSONDecoder().decode(ServerHello.self, from: shData)
    #expect(sh.devDeviceId == h.devDeviceId)
}

/// 防降级：未受信任 + 空 proof → rejectHelloIfUnauthorized 返回 .untrusted 的 RejectHello。
@Test func untrustedEmptyProofYieldsUntrustedRejectHello() throws {
    let h = try DialoutTrustHarness()
    let trust = try TrustStore(dir: h.trustDir)   // 空信任列表
    let context = DialoutContext(keyStore: h.devKeyStore, devDeviceId: h.devDeviceId,
                                 sessionId: "room-x", pairingCode: h.pairingCode,
                                 expiresAt: h.expiresAt, trust: trust)
    let hello = buildHello(sessionId: "room-x", ipadIdentity: h.ipadIdentity,
                           ipadEphemeral: h.ipadEphemeral, pairingCode: "unused", emptyProof: true)
    let reject = try context.rejectHelloIfUnauthorized(hello)
    #expect(reject != nil)
    #expect(reject?.reason == .untrusted)
    #expect(reject?.sessionId == "room-x")
    #expect(try Handshake.verifyRejectHello(reject!, clientHello: hello,
                                           devIdentityPub: h.devKeyStore.identityPublicKeyRaw) == .untrusted)
}

/// 未受信任 + 有效 proof → rejectHelloIfUnauthorized 返回 nil（交首配路径校验，不回归）。
@Test func untrustedWithValidProofNotRejected() throws {
    let h = try DialoutTrustHarness()
    let trust = try TrustStore(dir: h.trustDir)
    let context = DialoutContext(keyStore: h.devKeyStore, devDeviceId: h.devDeviceId,
                                 sessionId: "room-y", pairingCode: h.pairingCode,
                                 expiresAt: h.expiresAt, trust: trust)
    let hello = buildHello(sessionId: "room-y", ipadIdentity: h.ipadIdentity,
                           ipadEphemeral: h.ipadEphemeral, pairingCode: h.pairingCode, emptyProof: false)
    #expect(try context.rejectHelloIfUnauthorized(hello) == nil)
    // 且首配路径确实能成功走通。
    let (frame, ipadSession) = try driveHandshake(
        context: context, hello: hello, ipadIdentity: h.ipadIdentity,
        ipadEphemeral: h.ipadEphemeral, devIdentityPubRaw: h.devKeyStore.identityPublicKeyRaw)
    let ready = try JSONDecoder().decode(
        SecureReady.self, from: try ipadSession.open(try SecureEnvelope(decoding: frame)))
    #expect(ready.devDeviceId == h.devDeviceId)
}

@Test func clientHelloFailuresProduceSignedSpecificRejectReasons() throws {
    let h = try DialoutTrustHarness()
    let trust = try TrustStore(dir: h.trustDir)

    func rejection(context: DialoutContext, hello: ClientHello) throws -> RejectHello {
        var failure: Error?
        do { _ = try context.handleClientHello(JSONEncoder().encode(hello)) }
        catch { failure = error }
        let error = try #require(failure)
        let reject = try context.rejectHello(for: error, clientHello: hello)
        return try #require(reject)
    }

    let validHello = buildHello(sessionId: "room-reject", ipadIdentity: h.ipadIdentity,
                                ipadEphemeral: h.ipadEphemeral, pairingCode: h.pairingCode,
                                emptyProof: false)
    let expiredContext = DialoutContext(
        keyStore: h.devKeyStore, devDeviceId: h.devDeviceId, sessionId: "room-reject",
        pairingCode: h.pairingCode,
        expiresAt: Int64(Date().timeIntervalSince1970) - 1, trust: trust)
    let expired = try rejection(context: expiredContext, hello: validHello)
    #expect(try Handshake.verifyRejectHello(expired, clientHello: validHello,
                                            devIdentityPub: h.devKeyStore.identityPublicKeyRaw) == .pairingInvalid)

    let wrongProofContext = DialoutContext(
        keyStore: h.devKeyStore, devDeviceId: h.devDeviceId, sessionId: "room-proof",
        pairingCode: h.pairingCode, expiresAt: h.expiresAt, trust: trust)
    let wrongProof = buildHello(sessionId: "room-proof", ipadIdentity: h.ipadIdentity,
                                ipadEphemeral: h.ipadEphemeral, pairingCode: "wrong-code",
                                emptyProof: false)
    #expect(try rejection(context: wrongProofContext, hello: wrongProof).reason == .pairingInvalid)

    let versionContext = DialoutContext(
        keyStore: h.devKeyStore, devDeviceId: h.devDeviceId, sessionId: "room-reject",
        pairingCode: h.pairingCode, expiresAt: h.expiresAt, trust: trust)
    var wrongVersion = validHello
    wrongVersion.protocolVersion = "relay-e2e-v999"
    #expect(try rejection(context: versionContext, hello: wrongVersion).reason == .versionMismatch)
}

/// 重握手：受信任 iPad 在同一 DialoutContext 上连续两次完整握手（模拟弱网重连），
/// 都成功建 session、都回传 SecureReady，且 stableSessionId 幂等相同（不被 pairingConsumed 挡）。
@Test func trustedRehandshakeOnSameContextIsIdempotent() throws {
    let h = try DialoutTrustHarness()
    let trust = try TrustStore(dir: h.trustDir)
    try trust.trust(ipadPubB64: h.ipadPubB64, stableSessionId: "stable-fixed", label: nil)  // 预置信任
    let context = DialoutContext(keyStore: h.devKeyStore, devDeviceId: h.devDeviceId,
                                 sessionId: "room-a", pairingCode: h.pairingCode,
                                 expiresAt: h.expiresAt, trust: trust)

    func reconnect(_ sessionId: String) throws -> String {
        // 每次弱网重连都用新的临时交换密钥（真实场景），身份不变。
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let hello = buildHello(sessionId: sessionId, ipadIdentity: h.ipadIdentity,
                               ipadEphemeral: ephemeral, pairingCode: "unused", emptyProof: true)
        let (frame, ipadSession) = try driveHandshake(
            context: context, hello: hello, ipadIdentity: h.ipadIdentity,
            ipadEphemeral: ephemeral, devIdentityPubRaw: h.devKeyStore.identityPublicKeyRaw)
        let ready = try JSONDecoder().decode(
            SecureReady.self, from: try ipadSession.open(try SecureEnvelope(decoding: frame)))
        return ready.stableSessionId
    }

    let first = try reconnect("room-a")
    let second = try reconnect("room-b")   // 同一 context 再握手：不被上一次状态/pairingConsumed 挡
    #expect(first == "stable-fixed")
    #expect(second == "stable-fixed")      // stableSessionId 幂等相同
    #expect(trust.all().count == 1)        // 不新增信任记录
}

/// 防降级：未受信任 + 空 proof 绝不建 session——
/// rejectHelloIfUnauthorized 拦截，即便强行走 handleClientHello 也因 makeServerHello 验 proof 失败而抛。
@Test func downgradeUntrustedEmptyProofNeverBuildsSession() throws {
    let h = try DialoutTrustHarness()
    let trust = try TrustStore(dir: h.trustDir)
    let context = DialoutContext(keyStore: h.devKeyStore, devDeviceId: h.devDeviceId,
                                 sessionId: "room-z", pairingCode: h.pairingCode,
                                 expiresAt: h.expiresAt, trust: trust)
    let hello = buildHello(sessionId: "room-z", ipadIdentity: h.ipadIdentity,
                           ipadEphemeral: h.ipadEphemeral, pairingCode: "unused", emptyProof: true)
    #expect(try context.rejectHelloIfUnauthorized(hello)?.reason == .untrusted)   // 应被拦截
    // 即便无视拦截强行走握手，也必因空 proof 的 HMAC 校验失败而抛，绝不建 session。
    #expect(throws: HandshakeError.pairingCodeMismatch) {
        _ = try context.handleClientHello(JSONEncoder().encode(hello))
    }
    #expect(context.session == nil)
}

// MARK: - #2：dev 侧信任落盘成功后才发布会话 / 消费口令

/// #2：信任落盘失败时，handleClientAuth 必须向上抛错、不发布 _session、不消费口令、清握手临时态。
/// 在信任文件路径创建目录，令首配路径的 trust.trust 原子写稳定失败（包括以 root 运行的容器）。
@Test func trustPersistFailureDoesNotPublishSession() throws {
    let h = try DialoutTrustHarness()
    let trust = try TrustStore(dir: h.trustDir)   // init 时目录以 0700 建好，文件尚不存在
    try FileManager.default.createDirectory(
        at: h.trustDir.appendingPathComponent("trusted-ipads.json"),
        withIntermediateDirectories: false
    )

    let context = DialoutContext(keyStore: h.devKeyStore, devDeviceId: h.devDeviceId,
                                 sessionId: "room-1", pairingCode: h.pairingCode,
                                 expiresAt: h.expiresAt, trust: trust)
    let clientNonce = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
    let hello = Handshake.makeClientHello(
        sessionId: "room-1", ipadDeviceId: "ipad-1",
        ipadIdentityPub: h.ipadIdentity.publicKey.rawRepresentation,
        ipadEphemeralPub: h.ipadEphemeral.publicKey.rawRepresentation,
        clientNonce: clientNonce, pairingCode: h.pairingCode)
    let shData = try context.handleClientHello(JSONEncoder().encode(hello))
    let sh = try JSONDecoder().decode(ServerHello.self, from: shData)
    let auth = try Handshake.verifyServerHelloAndMakeClientAuth(
        clientHello: hello, serverHello: sh,
        devIdentityPub: h.devKeyStore.identityPublicKeyRaw, ipadIdentity: h.ipadIdentity)

    // 落盘失败 → handleClientAuth 向上抛错。
    #expect(throws: (any Error).self) {
        _ = try context.handleClientAuth(JSONEncoder().encode(auth))
    }
    // 关键 fail-closed 见证：session 未发布、一次性口令未消费（可重试，不被误标已用）。
    #expect(context.session == nil)
    #expect(context.pairingConsumed == false)
}

/// #2 回归：受信任复连（trusted 分支）语义不变——落盘成功即幂等发布会话、不消费一次性口令。
/// 用同一 context 连续两次受信任握手，均建 session、stableSessionId 幂等，且 pairingConsumed 保持 false。
@Test func trustedReconnectPublishAndConsumeSemanticsUnchanged() throws {
    let h = try DialoutTrustHarness()
    let trust = try TrustStore(dir: h.trustDir)
    try trust.trust(ipadPubB64: h.ipadPubB64, stableSessionId: "stable-fixed", label: nil)  // 预置信任
    let context = DialoutContext(keyStore: h.devKeyStore, devDeviceId: h.devDeviceId,
                                 sessionId: "room-a", pairingCode: h.pairingCode,
                                 expiresAt: h.expiresAt, trust: trust)

    func reconnect(_ sessionId: String) throws -> SecureReady {
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let hello = buildHello(sessionId: sessionId, ipadIdentity: h.ipadIdentity,
                               ipadEphemeral: ephemeral, pairingCode: "unused", emptyProof: true)
        let (frame, ipadSession) = try driveHandshake(
            context: context, hello: hello, ipadIdentity: h.ipadIdentity,
            ipadEphemeral: ephemeral, devIdentityPubRaw: h.devKeyStore.identityPublicKeyRaw)
        return try JSONDecoder().decode(SecureReady.self, from: try ipadSession.open(try SecureEnvelope(decoding: frame)))
    }

    let first = try reconnect("room-a")
    #expect(context.session != nil)              // 落盘成功后已发布会话
    #expect(context.pairingConsumed == false)    // 受信任复连不消费一次性口令
    let second = try reconnect("room-b")          // 同一 context 再握手仍成功（幂等）
    #expect(first.stableSessionId == "stable-fixed")
    #expect(second.stableSessionId == "stable-fixed")
    #expect(context.pairingConsumed == false)    // 仍不消费
    #expect(trust.all().count == 1)              // 不新增信任记录
}

/// 首配仍一次性：pairingCode 被首配消费后，另一台未受信任 iPad 用同一 code 二次首配握手被 pairingConsumed 挡。
@Test func firstPairingCodeRemainsOneTimeAgainstAnotherIpad() throws {
    let h = try DialoutTrustHarness()
    let trust = try TrustStore(dir: h.trustDir)
    let context = DialoutContext(keyStore: h.devKeyStore, devDeviceId: h.devDeviceId,
                                 sessionId: "room-1", pairingCode: h.pairingCode,
                                 expiresAt: h.expiresAt, trust: trust)
    // 第一台 iPad 首配成功，消费掉 pairingCode。
    let hello1 = buildHello(sessionId: "room-1", ipadIdentity: h.ipadIdentity,
                            ipadEphemeral: h.ipadEphemeral, pairingCode: h.pairingCode, emptyProof: false)
    _ = try driveHandshake(context: context, hello: hello1, ipadIdentity: h.ipadIdentity,
                           ipadEphemeral: h.ipadEphemeral, devIdentityPubRaw: h.devKeyStore.identityPublicKeyRaw)
    #expect(context.pairingConsumed)

    // 第二台未受信任 iPad 用同一 pairingCode 二次首配：必须被 pairingConsumed 挡。
    let ipad2 = Curve25519.Signing.PrivateKey()
    let ipad2Eph = Curve25519.KeyAgreement.PrivateKey()
    let hello2 = buildHello(sessionId: "room-2", ipadIdentity: ipad2,
                            ipadEphemeral: ipad2Eph, pairingCode: h.pairingCode, emptyProof: false)
    #expect(throws: DialoutHandshakeError.pairingAlreadyUsed) {
        _ = try context.handleClientHello(JSONEncoder().encode(hello2))
    }
}

// MARK: - relay-dialout-room-migration：稳定房间前置（首配 fallback = 启动房间号注入值）

/// ① 首配：落盘的稳定 sessionId == init 注入的启动房间号；SecureReady 回传同一值。
@Test func firstPairingAdoptsInjectedBootRoomAsStableSessionId() throws {
    let h = try DialoutTrustHarness()
    let trust = try TrustStore(dir: h.trustDir)
    let (frame, ipadSession) = try h.runHandshake(trust: trust, sessionId: "boot-room-1")

    #expect(trust.record(forPubB64: h.ipadPubB64)?.stableSessionId == "boot-room-1")
    let ready = try JSONDecoder().decode(
        SecureReady.self, from: try ipadSession.open(try SecureEnvelope(decoding: frame)))
    #expect(ready.stableSessionId == "boot-room-1")
}

/// ①b dev 权威性（防未来重构）：首配路径落盘值取 init 注入值，绝不取 hello.sessionId——
/// 恶意客户端/中转谎报 hello 房间号也无法污染持久化的稳定 sessionId（若改回 ?? hello.sessionId 此测试变红）。
@Test func firstPairingIgnoresHelloSessionIdUsesInjectedValue() throws {
    let h = try DialoutTrustHarness()
    let trust = try TrustStore(dir: h.trustDir)
    let context = DialoutContext(keyStore: h.devKeyStore, devDeviceId: h.devDeviceId,
                                 sessionId: "boot-authority", pairingCode: h.pairingCode,
                                 expiresAt: h.expiresAt, trust: trust)
    // hello 谎报房间号 "liar-room"（proof 按同一 pairingCode 正常生成，握手可过）。
    let hello = buildHello(sessionId: "liar-room", ipadIdentity: h.ipadIdentity,
                           ipadEphemeral: h.ipadEphemeral, pairingCode: h.pairingCode, emptyProof: false)
    let (frame, ipadSession) = try driveHandshake(
        context: context, hello: hello, ipadIdentity: h.ipadIdentity,
        ipadEphemeral: h.ipadEphemeral, devIdentityPubRaw: h.devKeyStore.identityPublicKeyRaw)
    let ready = try JSONDecoder().decode(
        SecureReady.self, from: try ipadSession.open(try SecureEnvelope(decoding: frame)))
    #expect(trust.record(forPubB64: h.ipadPubB64)?.stableSessionId == "boot-authority")
    #expect(ready.stableSessionId == "boot-authority")
}

/// ② 复连模式不退化：预置信任记录时，即便注入值与记录值不同（结构上 main 不会发生，
/// 防未来重构破坏不变量），落盘/回传仍为记录值——注入值不覆盖。
@Test func reconnectModeRecordValueWinsOverInjectedSessionId() throws {
    let h = try DialoutTrustHarness()
    let trust = try TrustStore(dir: h.trustDir)
    try trust.trust(ipadPubB64: h.ipadPubB64, stableSessionId: "stable-preset", label: nil)
    let context = DialoutContext(keyStore: h.devKeyStore, devDeviceId: h.devDeviceId,
                                 sessionId: "injected-other", pairingCode: h.pairingCode,
                                 expiresAt: h.expiresAt, trust: trust)
    let ephemeral = Curve25519.KeyAgreement.PrivateKey()
    let hello = buildHello(sessionId: "stable-preset", ipadIdentity: h.ipadIdentity,
                           ipadEphemeral: ephemeral, pairingCode: "unused", emptyProof: true)
    let (frame, ipadSession) = try driveHandshake(
        context: context, hello: hello, ipadIdentity: h.ipadIdentity,
        ipadEphemeral: ephemeral, devIdentityPubRaw: h.devKeyStore.identityPublicKeyRaw)
    let ready = try JSONDecoder().decode(
        SecureReady.self, from: try ipadSession.open(try SecureEnvelope(decoding: frame)))
    #expect(ready.stableSessionId == "stable-preset")
    #expect(trust.record(forPubB64: h.ipadPubB64)?.stableSessionId == "stable-preset")
}

/// ③ 同运行内重握手：首配采用注入值落盘后，同一 context 第二轮握手（此时已受信任）
/// 复用记录值 == 注入值，不再新生成。
@Test func sameRunRehandshakeReusesRecordedBootRoom() throws {
    let h = try DialoutTrustHarness()
    let trust = try TrustStore(dir: h.trustDir)
    let context = DialoutContext(keyStore: h.devKeyStore, devDeviceId: h.devDeviceId,
                                 sessionId: "boot-room-3", pairingCode: h.pairingCode,
                                 expiresAt: h.expiresAt, trust: trust)
    // 第一轮：首配（带 proof）。
    let hello1 = buildHello(sessionId: "boot-room-3", ipadIdentity: h.ipadIdentity,
                            ipadEphemeral: h.ipadEphemeral, pairingCode: h.pairingCode, emptyProof: false)
    let (frame1, session1) = try driveHandshake(
        context: context, hello: hello1, ipadIdentity: h.ipadIdentity,
        ipadEphemeral: h.ipadEphemeral, devIdentityPubRaw: h.devKeyStore.identityPublicKeyRaw)
    let ready1 = try JSONDecoder().decode(
        SecureReady.self, from: try session1.open(try SecureEnvelope(decoding: frame1)))
    #expect(ready1.stableSessionId == "boot-room-3")
    // 第二轮：同一 context 受信任重握手（空 proof + 新临时交换密钥，模拟弱网重连）。
    let eph2 = Curve25519.KeyAgreement.PrivateKey()
    let hello2 = buildHello(sessionId: "boot-room-3", ipadIdentity: h.ipadIdentity,
                            ipadEphemeral: eph2, pairingCode: "unused", emptyProof: true)
    let (frame2, session2) = try driveHandshake(
        context: context, hello: hello2, ipadIdentity: h.ipadIdentity,
        ipadEphemeral: eph2, devIdentityPubRaw: h.devKeyStore.identityPublicKeyRaw)
    let ready2 = try JSONDecoder().decode(
        SecureReady.self, from: try session2.open(try SecureEnvelope(decoding: frame2)))
    #expect(ready2.stableSessionId == "boot-room-3")
    #expect(trust.all().count == 1)   // 幂等，不新增信任记录
}

/// ④ 轮换出口：两次独立首配（清信任重来，模拟 --forget-all 后重启生成新随机房间）
/// 产生不同的稳定 sessionId——各自等于各自的启动房间号。
@Test func independentFirstPairingsYieldDistinctStableSessionIds() throws {
    let h = try DialoutTrustHarness()
    let boot1 = "boot-" + UUID().uuidString
    let boot2 = "boot-" + UUID().uuidString
    let trust1 = try TrustStore(dir: h.trustDir)
    _ = try h.runHandshake(trust: trust1, sessionId: boot1)
    let first = trust1.record(forPubB64: h.ipadPubB64)?.stableSessionId
    // 清信任重来 = 全新信任目录（等价 --forget-all 后重启）。
    let trust2 = try TrustStore(
        dir: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    _ = try h.runHandshake(trust: trust2, sessionId: boot2)
    let second = trust2.record(forPubB64: h.ipadPubB64)?.stableSessionId
    #expect(first == boot1)
    #expect(second == boot2)
    #expect(first != second)
}
