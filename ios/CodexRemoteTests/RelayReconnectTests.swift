import XCTest
import Crypto
import RelayProtocol
@testable import CodexRemote

/// E1：RelayTransport 断线自动重连状态机测试。
///
/// 用**可编程 channel factory**（脚本化「第 N 次连接：成功 / 连接失败 / 返回 RejectHello」）驱动重连逻辑，
/// 完全脱离真网络。成功连接复用 `DevResponder`（真握手 + 回声）；瞬断由主动 close 掉当前回环通道模拟。
/// 退避 sleep 注入为 no-op（记录请求秒数），避免真 sleep。
@MainActor
final class RelayReconnectTests: XCTestCase {

    // MARK: 脚本化 channel factory

    enum ConnectBehavior { case succeed, failConnect, reject, rejectReason(RejectReason), forgedReject }

    /// 线程安全的连接脚本：按顺序为每次 factory 调用返回一个通道（或抛错模拟连接失败）。
    /// 成功通道复用同一 dev 身份（跨重连 TOFU 一致），并留存最近成功通道供测试模拟瞬断。
    final class ReconnectScript: @unchecked Sendable {
        private let lock = NSLock()
        private var behaviors: [ConnectBehavior]
        private var index = 0
        private var _connectCount = 0
        private var _currentChannel: LoopbackRelayWSChannel?

        let devIdentity: Curve25519.Signing.PrivateKey
        let pairingCode: String
        let stableSessionId: String

        init(_ behaviors: [ConnectBehavior], pairingCode: String = "reconnect-code",
             stableSessionId: String = "stable-reconnect",
             devIdentity: Curve25519.Signing.PrivateKey = .init()) {
            self.behaviors = behaviors
            self.pairingCode = pairingCode
            self.stableSessionId = stableSessionId
            self.devIdentity = devIdentity
        }

        var devIdentityPubB64: String { devIdentity.publicKey.rawRepresentation.base64EncodedString() }
        var connectCount: Int { lock.lock(); defer { lock.unlock() }; return _connectCount }
        var currentChannel: LoopbackRelayWSChannel? {
            lock.lock(); defer { lock.unlock() }; return _currentChannel
        }

        /// factory 主体：取下一个行为，成功造回环通道，失败抛错。行为耗尽后默认 `failConnect`。
        func makeChannel() throws -> RelayWSChannel {
            lock.lock()
            let behavior = index < behaviors.count ? behaviors[index] : .failConnect
            index += 1
            _connectCount += 1
            lock.unlock()
            switch behavior {
            case .failConnect:
                throw TransportError.channelClosed(reason: "脚本模拟连接失败")
            case .reject:
                return LoopbackRelayWSChannel { text in
                    let hello = try JSONDecoder().decode(ClientHello.self, from: Data(text.utf8))
                    let rej = try Handshake.makeRejectHello(clientHello: hello, reason: .trustRevoked,
                                                            devIdentity: self.devIdentity)
                    return String(decoding: try JSONEncoder().encode(rej), as: UTF8.self)
                }
            case .rejectReason(let reason):
                return LoopbackRelayWSChannel { text in
                    let hello = try JSONDecoder().decode(ClientHello.self, from: Data(text.utf8))
                    let reject = try Handshake.makeRejectHello(clientHello: hello, reason: reason,
                                                               devIdentity: self.devIdentity)
                    return String(decoding: try JSONEncoder().encode(reject), as: UTF8.self)
                }
            case .forgedReject:
                return LoopbackRelayWSChannel { text in
                    let hello = try JSONDecoder().decode(ClientHello.self, from: Data(text.utf8))
                    let attacker = Curve25519.Signing.PrivateKey()
                    let rej = try Handshake.makeRejectHello(clientHello: hello, reason: .trustRevoked,
                                                            devIdentity: attacker)
                    return String(decoding: try JSONEncoder().encode(rej), as: UTF8.self)
                }
            case .succeed:
                let dev = DevResponder(pairingCode: pairingCode, stableSessionId: stableSessionId,
                                       devIdentity: devIdentity)
                let ch = LoopbackRelayWSChannel { try dev.handle($0) }
                lock.lock(); _currentChannel = ch; lock.unlock()
                return ch
            }
        }
    }

    /// 记录退避请求秒数（不真 sleep），用于验证退避有界 + 封顶。
    final class SleepRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _seconds: [Double] = []
        func record(_ s: Double) { lock.lock(); _seconds.append(s); lock.unlock() }
        var seconds: [Double] { lock.lock(); defer { lock.unlock() }; return _seconds }
    }

    private func pairing(_ script: ReconnectScript) -> PairingPayload {
        PairingPayload(relayURL: "wss://relay.test", sessionId: "sess-reconnect",
                       devIdentityPubB64: script.devIdentityPubB64,
                       pairingCode: script.pairingCode, expiresAt: 9_999_999_999)
    }

    /// 构造受信任复连 transport：脚本化 factory + 新 ephemeral 每握手 + 注入退避策略。
    private func makeTransport(_ script: ReconnectScript,
                               policy: RelayReconnectPolicy,
                               tofu: TOFUStoring = InMemoryTOFUStore()) -> RelayTransport {
        RelayTransport(
            channelFactory: { try script.makeChannel() },
            pairing: pairing(script),
            ipadIdentity: Curve25519.Signing.PrivateKey(),
            ephemeralProvider: { Curve25519.KeyAgreement.PrivateKey() },
            tofu: tofu, tofuMachineKey: "machine-reconnect",
            isTrustedReconnect: true,
            stableSessionStore: InMemoryStableSessionStore(),
            reconnect: policy)
    }

    // MARK: 测试

    /// 重连并复握手：首连成功 → 模拟瞬断 → factory 被再次调用 → 重连握手成功 →
    /// control 序列含 .reconnecting 后 .ready；incoming 流跨重连存活（.ready 后仍能 yield 业务帧）。
    func testReconnectRehandshakesAndIncomingSurvives() async throws {
        let script = ReconnectScript([.succeed, .succeed])
        let policy = RelayReconnectPolicy(maxAttempts: 6, baseDelaySeconds: 0.0, maxDelaySeconds: 0.0,
                                          sleep: { _ in })
        let transport = makeTransport(script, policy: policy)

        var iter = transport.incoming().makeAsyncIterator()
        var ctrl = transport.control().makeAsyncIterator()
        try await transport.awaitHandshake()

        // 首连业务往返（ws1）。
        try await transport.send("a")
        let a = try await iter.next()
        XCTAssertEqual(a, "a-echo")
        XCTAssertEqual(script.connectCount, 1)

        // 模拟瞬断：关掉当前回环通道（非 transport.close → 视为瞬断）。
        await script.currentChannel?.close()

        // control 序列：.reconnecting 后 .ready。
        let e1 = await ctrl.next()
        XCTAssertEqual(e1, .reconnecting)
        let e2 = await ctrl.next()
        XCTAssertEqual(e2, .ready)
        XCTAssertEqual(script.connectCount, 2)   // factory 被再次调用

        // incoming 跨重连存活：同一 iter 在 .ready 后继续收业务帧（ws2）。
        try await transport.send("b")
        let b = try await iter.next()
        XCTAssertEqual(b, "b-echo")

        await transport.close()
    }

    /// 退避达上限：首连成功 → 瞬断 → 工厂持续失败 maxAttempts 次 → emit .connectionFailed →
    /// incoming finish(throwing)；退避不无限（尝试有界）且封顶（每次 sleep ≤ maxDelay）。
    func testBackoffReachesCapThenConnectionFailed() async throws {
        let maxAttempts = 4
        let script = ReconnectScript([.succeed] + Array(repeating: .failConnect, count: 10))
        let recorder = SleepRecorder()
        let policy = RelayReconnectPolicy(maxAttempts: maxAttempts, baseDelaySeconds: 0.01,
                                          maxDelaySeconds: 0.05,
                                          sleep: { s in recorder.record(s) })
        let transport = makeTransport(script, policy: policy)

        var iter = transport.incoming().makeAsyncIterator()
        var ctrl = transport.control().makeAsyncIterator()
        try await transport.awaitHandshake()
        XCTAssertEqual(script.connectCount, 1)

        await script.currentChannel?.close()

        // 每次尝试前发 .reconnecting；耗尽后终态 .connectionFailed。
        var events: [TransportControlEvent] = []
        while let ev = await ctrl.next() {
            events.append(ev)
            if ev == .connectionFailed { break }
        }
        XCTAssertEqual(events.last, .connectionFailed)
        XCTAssertEqual(events.filter { $0 == .reconnecting }.count, maxAttempts)

        // 尝试有界：首连 1 次 + 重连 maxAttempts 次。
        XCTAssertEqual(script.connectCount, 1 + maxAttempts)

        // 退避封顶：所有请求秒数 ≤ maxDelay，且序列长度 == maxAttempts（不无限）。
        XCTAssertEqual(recorder.seconds.count, maxAttempts)
        for s in recorder.seconds { XCTAssertLessThanOrEqual(s, 0.05 + 1e-9) }
        // 指数增长后被封顶：最后一次达上限。
        XCTAssertEqual(recorder.seconds.last!, 0.05, accuracy: 1e-9)

        // incoming 终态：抛错终止（非挂起、非正常结束）。
        do {
            _ = try await iter.next()
            XCTFail("退避耗尽后 incoming 应抛错终止")
        } catch { /* 预期 channelClosed */ }
    }

    /// 收 RejectHello 不重连：瞬断后重连握手时 dev 回 RejectHello → emit .trustRevoked →
    /// 工厂不再被调用（不重连）→ incoming finish。
    func testRejectHelloEmitsTrustRevokedAndStopsReconnect() async throws {
        let script = ReconnectScript([.succeed, .reject])
        let policy = RelayReconnectPolicy(maxAttempts: 6, baseDelaySeconds: 0.0, maxDelaySeconds: 0.0,
                                          sleep: { _ in })
        let transport = makeTransport(script, policy: policy)

        var iter = transport.incoming().makeAsyncIterator()
        var ctrl = transport.control().makeAsyncIterator()
        try await transport.awaitHandshake()
        XCTAssertEqual(script.connectCount, 1)

        await script.currentChannel?.close()

        // 序列：.reconnecting → .trustRevoked（终态，不再 .reconnecting）。
        let e1 = await ctrl.next()
        XCTAssertEqual(e1, .reconnecting)
        let e2 = await ctrl.next()
        XCTAssertEqual(e2, .trustRevoked)

        // 工厂正好被调用 2 次（首连 + 一次 reject），不再重连。
        XCTAssertEqual(script.connectCount, 2)

        // incoming 终态：抛错终止。
        do {
            _ = try await iter.next()
            XCTFail("收 RejectHello 后 incoming 应抛错终止")
        } catch { /* 预期 */ }
    }

    func testPairingInvalidRejectPreservesReasonAndStopsReconnect() async throws {
        let script = ReconnectScript([.succeed, .rejectReason(.pairingInvalid)])
        let policy = RelayReconnectPolicy(maxAttempts: 6, baseDelaySeconds: 0, maxDelaySeconds: 0,
                                          sleep: { _ in })
        let transport = makeTransport(script, policy: policy)
        var incoming = transport.incoming().makeAsyncIterator()
        var control = transport.control().makeAsyncIterator()
        try await transport.awaitHandshake()

        await script.currentChannel?.close()
        let reconnecting = await control.next()
        let rejected = await control.next()
        XCTAssertEqual(reconnecting, .reconnecting)
        XCTAssertEqual(rejected, .handshakeRejected(.pairingInvalid))
        XCTAssertEqual(script.connectCount, 2)
        do {
            _ = try await incoming.next()
            XCTFail("pairing rejection should terminate incoming")
        } catch let error as TransportError {
            XCTAssertEqual(error, .handshakeRejected(.pairingInvalid))
        }
    }

    func testForgedRejectDoesNotRevokeTrustAndConsumesReconnectBudget() async throws {
        let script = ReconnectScript([.succeed, .forgedReject, .failConnect])
        let policy = RelayReconnectPolicy(maxAttempts: 2, baseDelaySeconds: 0.0, maxDelaySeconds: 0.0,
                                          sleep: { _ in })
        let transport = makeTransport(script, policy: policy)
        var ctrl = transport.control().makeAsyncIterator()
        try await transport.awaitHandshake()

        await script.currentChannel?.close()

        var events: [TransportControlEvent] = []
        while let event = await ctrl.next() {
            events.append(event)
            if event == .connectionFailed { break }
        }
        XCTAssertFalse(events.contains(.trustRevoked),
                       "relay 用错误身份签名的拒绝不得改变配对信任状态")
        XCTAssertEqual(events.last, .connectionFailed)
        XCTAssertEqual(script.connectCount, 3)
    }

    /// 主动 close：close() 后 incoming 正常 finish（返回 nil，不抛错），不触发重连（工厂不再被调用）。
    func testActiveCloseFinishesWithoutReconnect() async throws {
        let script = ReconnectScript([.succeed])
        let policy = RelayReconnectPolicy(maxAttempts: 6, baseDelaySeconds: 0.0, maxDelaySeconds: 0.0,
                                          sleep: { _ in })
        let transport = makeTransport(script, policy: policy)

        var iter = transport.incoming().makeAsyncIterator()
        try await transport.awaitHandshake()
        try await transport.send("a")
        let a = try await iter.next()
        XCTAssertEqual(a, "a-echo")
        XCTAssertEqual(script.connectCount, 1)

        await transport.close()

        // 主动 close：incoming 正常结束（nil），非抛错。
        let tail = try await iter.next()
        XCTAssertNil(tail)
        // 不重连：工厂仍只被调用 1 次。
        XCTAssertEqual(script.connectCount, 1)
    }

    /// 能耗：后台暂停重连（4.5）。首连成功 → 切后台 → 瞬断进重连循环，
    /// 后台期间 factory **不再被调用**（挂起等待回前台，不持续造连接烧电）；
    /// 切回前台 → 重连恢复 → factory 被调用 → .ready。
    func testBackgroundPausesReconnectUntilForeground() async throws {
        let script = ReconnectScript([.succeed, .succeed])
        let policy = RelayReconnectPolicy(maxAttempts: 6, baseDelaySeconds: 0.0, maxDelaySeconds: 0.0,
                                          sleep: { _ in })
        let transport = makeTransport(script, policy: policy)

        var ctrl = transport.control().makeAsyncIterator()
        try await transport.awaitHandshake()
        XCTAssertEqual(script.connectCount, 1)

        // 先切后台，再瞬断：重连循环进入即因后台而挂起，绝不触发 factory。
        await transport.setForeground(false)
        await script.currentChannel?.close()

        // 后台窗口内 factory 不被调用（proving negative：给足时间证明确实暂停）。
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(script.connectCount, 1, "后台应暂停重连：factory 不被调用")

        // 切回前台 → 恢复重连 → factory 被调用 → .ready。
        await transport.setForeground(true)
        var sawReady = false
        for _ in 0..<10 {
            if let ev = await ctrl.next(), ev == .ready { sawReady = true; break }
        }
        XCTAssertTrue(sawReady, "回前台后应重连成功发 .ready")
        XCTAssertEqual(script.connectCount, 2, "回前台后恢复重连，factory 再被调用")

        await transport.close()
    }

    /// 线程安全的一次性钩子：首次退避 sleep 时把 transport 切后台，制造「退避期间转后台」时序。
    final class BackgroundOnFirstSleep: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        weak var transport: RelayTransport?
        /// 同步取"是否首次"（锁只在同步上下文持有，避免 Swift 6 async 上下文禁用 NSLock）。
        private func claimFirst() -> Bool {
            lock.lock(); defer { lock.unlock() }
            let first = !fired; fired = true; return first
        }
        func onSleep() async {
            guard claimFirst(), let t = transport else { return }
            await t.setForeground(false)
        }
    }

    /// D3：退避 sleep 期间 app 转入后台 → 退避结束后**不**创建通道（factory 不被调用）；
    /// 回前台后才建通道握手。区别于 testBackgroundPausesReconnectUntilForeground
    ///（那是断线前已后台，循环顶部挂起）：本用例后台发生在退避 sleep 之中，由退避后新增的 waitForForeground() 兜住。
    func testBackgroundDuringBackoffDefersFactoryUntilForeground() async throws {
        let script = ReconnectScript([.succeed, .succeed])
        let flip = BackgroundOnFirstSleep()
        let policy = RelayReconnectPolicy(maxAttempts: 6, baseDelaySeconds: 0.0, maxDelaySeconds: 0.0,
                                          sleep: { _ in await flip.onSleep() })
        let transport = makeTransport(script, policy: policy)
        flip.transport = transport

        var ctrl = transport.control().makeAsyncIterator()
        try await transport.awaitHandshake()
        XCTAssertEqual(script.connectCount, 1)

        await script.currentChannel?.close()

        let e1 = await ctrl.next()
        XCTAssertEqual(e1, .reconnecting, "退避前应先发 .reconnecting")

        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(script.connectCount, 1, "退避中转后台后不得创建新通道（factory 不被调用）")

        await transport.setForeground(true)
        var sawReady = false
        for _ in 0..<10 { if let ev = await ctrl.next(), ev == .ready { sawReady = true; break } }
        XCTAssertTrue(sawReady, "回前台后应重连成功发 .ready")
        XCTAssertEqual(script.connectCount, 2, "回前台后才创建新通道，factory 再被调用")

        await transport.close()
    }

    // MARK: 缺口 2 消费——peer-left 提示 + 主动重连

    /// relay 下发 peer-left 明文帧 → RelayTransport 发 .peerLeft 控制事件，且不断开、不进重连。
    func testPeerLeftFrameEmitsPeerLeftControlWithoutDisconnect() async throws {
        let script = ReconnectScript([.succeed])
        let policy = RelayReconnectPolicy(maxAttempts: 6, baseDelaySeconds: 0.0, maxDelaySeconds: 0.0,
                                          sleep: { _ in })
        let transport = makeTransport(script, policy: policy)

        var iter = transport.incoming().makeAsyncIterator()
        var ctrl = transport.control().makeAsyncIterator()
        try await transport.awaitHandshake()
        XCTAssertEqual(script.connectCount, 1)

        let sig = try RelaySignal(kind: RelaySignal.peerLeftKind, sessionId: "sess-reconnect").encoded()
        await script.currentChannel?.inject(String(decoding: sig, as: UTF8.self))

        let ev = await ctrl.next()
        XCTAssertEqual(ev, .peerLeft, "peer-left 应发 .peerLeft 控制事件")
        XCTAssertNotEqual(ev, .reconnecting, "peer-left 不得触发重连")
        XCTAssertNotEqual(ev, .connectionFailed)

        try await transport.send("a")
        let a = try await iter.next()
        XCTAssertEqual(a, "a-echo")
        XCTAssertEqual(script.connectCount, 1, "peer-left 不得触发重连（factory 不再被调用）")

        await transport.close()
    }

    func testPeerLeftForDifferentSessionIsIgnored() async throws {
        let script = ReconnectScript([.succeed])
        let policy = RelayReconnectPolicy(maxAttempts: 6, baseDelaySeconds: 0.0, maxDelaySeconds: 0.0,
                                          sleep: { _ in })
        let transport = makeTransport(script, policy: policy)
        try await transport.awaitHandshake()

        let collected = Task { () -> [TransportControlEvent] in
            var events: [TransportControlEvent] = []
            for await event in transport.control() { events.append(event) }
            return events
        }
        let signal = try RelaySignal(kind: RelaySignal.peerLeftKind,
                                     sessionId: "different-session").encoded()
        await script.currentChannel?.inject(String(decoding: signal, as: UTF8.self))
        try? await Task.sleep(for: .milliseconds(50))
        await transport.close()

        let events = await collected.value
        XCTAssertFalse(events.contains(.peerLeft),
                       "其它 relay session 的 peer-left 不得影响当前连接")
    }

    /// triggerReconnect 主动丢弃当前 ws → 走既有内部有界重连（先 .reconnecting、再 .ready），不置 activeClose。
    func testTriggerReconnectStartsBoundedReconnect() async throws {
        let script = ReconnectScript([.succeed, .succeed])
        let policy = RelayReconnectPolicy(maxAttempts: 6, baseDelaySeconds: 0.0, maxDelaySeconds: 0.0,
                                          sleep: { _ in })
        let transport = makeTransport(script, policy: policy)

        var ctrl = transport.control().makeAsyncIterator()
        try await transport.awaitHandshake()
        XCTAssertEqual(script.connectCount, 1)

        await transport.triggerReconnect()

        let e1 = await ctrl.next()
        XCTAssertEqual(e1, .reconnecting, "triggerReconnect 应启动内部有界重连")
        let e2 = await ctrl.next()
        XCTAssertEqual(e2, .ready)
        XCTAssertEqual(script.connectCount, 2, "重连复用既有 channelFactory 有界路径")

        await transport.close()
    }
}
