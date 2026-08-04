import XCTest
import Crypto
import RelayProtocol
@testable import CodexRemote

/// A3：iPad `performHandshakeOn` 的 `receiveText()` 无超时会导致重连永久挂起（缺陷 #1）。
///
/// 用可编程 channel factory：首连成功（复用 `DevResponder` 真握手）；瞬断后重连命中一个
/// **永不回应**的 mock 通道（`NeverRespondingChannel`，卡在等 ServerHello）。修复前，
/// `performHandshakeOn` 里的 `receiveText()` 没有超时——重连会永久挂起，既不发
/// `.connectionFailed`，也不会让失败计入 `RelayReconnectPolicy.maxAttempts` 预算。
///
/// 本测试用**有界看门狗**（几秒）把"永久挂起"这一缺陷现象转成可观察、及时失败的红——
/// 不然真的永久挂起会拖死测试进程本身。看门狗只是把 hang 变成可断言的 timeout；
/// 修复后正常路径会在看门狗触发前正常完成，看门狗退化为安全网。
@MainActor
final class RelayHandshakeTimeoutTests: XCTestCase {

    /// 永不回应的 mock 通道：`receiveText()` 挂在可取消的 `Task.sleep(.max)` 上，
    /// 忠实模拟"对端永不下发 ServerHello/SecureReady"，同时保持可取消
    /// （不像 `withCheckedContinuation` 那样会让 `withThrowingTaskGroup` 的隐式收尾也被拖住）。
    actor NeverRespondingChannel: RelayWSChannel {
        func sendText(_ text: String) async throws {}
        func receiveText() async throws -> String? {
            try await Task.sleep(nanoseconds: .max)
            return nil
        }
        func close() async {}
    }

    /// 脚本化 factory：第 1 次连接成功（真握手 + DevResponder 回声）；之后每次都返回
    /// 永不回应的通道（模拟重连总是卡在等 ServerHello/SecureReady）。
    final class TimeoutScript: @unchecked Sendable {
        private let lock = NSLock()
        private var _connectCount = 0
        private var _currentChannel: LoopbackRelayWSChannel?

        let devIdentity: Curve25519.Signing.PrivateKey
        let pairingCode: String

        init(pairingCode: String = "timeout-code",
             devIdentity: Curve25519.Signing.PrivateKey = .init()) {
            self.pairingCode = pairingCode
            self.devIdentity = devIdentity
        }

        var devIdentityPubB64: String { devIdentity.publicKey.rawRepresentation.base64EncodedString() }
        var connectCount: Int { lock.lock(); defer { lock.unlock() }; return _connectCount }
        var currentChannel: LoopbackRelayWSChannel? {
            lock.lock(); defer { lock.unlock() }; return _currentChannel
        }

        func makeChannel() throws -> RelayWSChannel {
            lock.lock()
            _connectCount += 1
            let isFirst = _connectCount == 1
            lock.unlock()
            if isFirst {
                let dev = DevResponder(pairingCode: pairingCode, devIdentity: devIdentity)
                let ch = LoopbackRelayWSChannel { try dev.handle($0) }
                lock.lock(); _currentChannel = ch; lock.unlock()
                return ch
            }
            return NeverRespondingChannel()
        }
    }

    private func pairing(_ script: TimeoutScript) -> PairingPayload {
        PairingPayload(relayURL: "wss://relay.test", sessionId: "sess-timeout",
                       devIdentityPubB64: script.devIdentityPubB64,
                       pairingCode: script.pairingCode, expiresAt: 9_999_999_999)
    }

    private func makeTransport(_ script: TimeoutScript, policy: RelayReconnectPolicy) -> RelayTransport {
        RelayTransport(
            channelFactory: { try script.makeChannel() },
            pairing: pairing(script),
            ipadIdentity: Curve25519.Signing.PrivateKey(),
            ephemeralProvider: { Curve25519.KeyAgreement.PrivateKey() },
            tofu: InMemoryTOFUStore(), tofuMachineKey: "machine-timeout",
            isTrustedReconnect: true,
            stableSessionStore: InMemoryStableSessionStore(),
            reconnect: policy)
    }

    /// 缺陷 #1 复现 + 修复验证：ServerHello 永不到时，`performHandshakeOn` 必须在有界时间内
    /// 抛错（不永久挂起），且该次失败计入 `RelayReconnectPolicy` 的尝试预算——
    /// 最终耗尽预算后进入 `.connectionFailed` 终态，重连次数恰为 `1 + maxAttempts`
    /// （不新开无界等待、不绕过既有退避/上限）。
    func testHandshakeReceiveTimesOutAndCountsAsReconnectAttempt() async throws {
        let maxAttempts = 2
        let script = TimeoutScript()
        // receiveTimeoutSeconds 短且注入的 receiveTimeoutSleep 真短 sleep（非 no-op）：
        // 若借用退避 sleep 的 no-op 语义，超时分支会在所有握手（包括首连的真实成功收发）里都
        // "瞬间"抢跑，把正常收发也误判成超时——两个 sleep 钩子语义不同故分开注入（见
        // RelayReconnectPolicy.receiveTimeoutSleep 文档）。0.05s 远小于看门狗，不拖慢测试。
        let policy = RelayReconnectPolicy(maxAttempts: maxAttempts, baseDelaySeconds: 0.0,
                                          maxDelaySeconds: 0.0, sleep: { _ in },
                                          receiveTimeoutSeconds: 0.05,
                                          receiveTimeoutSleep: { s in
                                              try? await Task.sleep(nanoseconds: UInt64(max(0, s) * 1_000_000_000))
                                          })
        let transport = makeTransport(script, policy: policy)

        // 用 AsyncStream 值本身（Sendable）而非本地可变迭代器变量：整条消费循环放进
        // 一个独立 Task 内部用 `for await` 跑完，避免把非 Sendable 的迭代器状态跨隔离域发送。
        let controlStream = transport.control()
        try await transport.awaitHandshake()
        XCTAssertEqual(script.connectCount, 1, "首连应成功且只调一次 factory")

        // 模拟瞬断：关掉当前回环通道 → 进入重连循环 → 下一次 factory 调用命中永不回应通道。
        await script.currentChannel?.close()

        // 有界看门狗：给足时间证明"不是挂起"，而不是无限期等最终事件。
        // 修复前：performHandshakeOn 卡在等 ServerHello 的 receiveText() 上，永不返回，
        // control 流永远不会再吐出 .connectionFailed —— 看门狗会先触发，测试失败（红）。
        let watchdogSeconds: UInt64 = 6
        let collector = Task<[TransportControlEvent], Never> {
            var events: [TransportControlEvent] = []
            for await ev in controlStream {
                events.append(ev)
                if ev == .connectionFailed { break }
                if events.count > maxAttempts + 5 { break } // 安全帽，防脚本行为异常时无限循环
            }
            return events
        }
        // 关键：`withTaskGroup` 在返回前会隐式等所有子任务真正跑完（`cancelAll()` 只是
        // 协作式取消信号）。若看门狗分支赢了却只在 group 返回*之后*才 cancel(collector)，
        // 则 `{ await collector.value }` 这个子任务在 group 内部永远等不到 collector 结束——
        // group 本身就会跟着永久挂起（正是本 fix 要避免在 receiveTextWithTimeout 里犯的错误，
        // 这里先在测试脚手架里踩了一次）。修法：cancel 必须发生在**赢的那个分支自己返回之前**，
        // 让 collector 的 `for await` 观察到取消提前结束，`.value` 才能跟着解开。
        let events: [TransportControlEvent]? = await withTaskGroup(of: [TransportControlEvent]?.self) { group in
            group.addTask { await collector.value }
            group.addTask {
                try? await Task.sleep(nanoseconds: watchdogSeconds * 1_000_000_000)
                collector.cancel()
                return nil
            }
            let first = await group.next()
            collector.cancel()
            group.cancelAll()
            return first ?? nil
        }

        guard let events else {
            await transport.close()
            XCTFail("""
                缺陷 #1 复现：ServerHello 永不到时，performHandshakeOn 的 receiveText() 无超时，
                重连在 \(watchdogSeconds)s 看门狗内未产生任何终态事件（未见 .connectionFailed）——
                该次失败因此也未计入 RelayReconnectPolicy 的尝试预算，永久挂起而非有界失败。
                """)
            return
        }

        XCTAssertEqual(events.last, .connectionFailed,
                       "接收超时后应耗尽重连预算并进入 .connectionFailed 终态")
        XCTAssertEqual(events.filter { $0 == .reconnecting }.count, maxAttempts,
                       "每次重连尝试前都应先发 .reconnecting（计入预算的直接证据）")
        XCTAssertEqual(script.connectCount, 1 + maxAttempts,
                       "接收超时的失败应计入尝试预算：factory 恰被调用 1(首连) + maxAttempts(重连) 次，不多不少")

        await transport.close()
    }
}
