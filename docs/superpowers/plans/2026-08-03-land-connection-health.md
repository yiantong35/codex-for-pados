---
change: land-connection-health
design-doc: docs/superpowers/specs/2026-08-03-land-connection-health-design.md
base-ref: 27f47185108eb0983d02241dac218c915b6286db
archived-with: 2026-08-04-land-connection-health
---

# land-connection-health 实现计划

> **给执行者（agentic worker）：** 必需子技能：用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 按任务逐条执行本计划。步骤用 `- [ ]` 复选框跟踪。本 change 走 **tdd_mode**：每个任务先写失败测试（red），再写最小实现（green），再提交。

**目标：** 在无-SSH master 基线上重新落地「连接健康可见性」能力（端到端心跳判死、relay peer-left 提示、断线横幅三态、tab 灰点、relay 两端 peer-left 信令），并修正一条引用已删 SSH 的过时 spec。

**架构：** 近乎干净的**语义移植**——参考 PR #45（origin 分支 `worktree-feature+20260802+connection-health-visibility`，merge-base `8b778a40`）的逻辑 diff，在当前 master 版本上**只叠加连接健康 delta**。协议层 `RelaySignal`（连接层信号帧，非 E2E）由 relay-server 在一端离开时明文下发；iOS 端 `HeartbeatMonitor` 用 `getAuthStatus` 往返探活，连续错过 2 次判死 → 触发有界重连；peer-left 仅作「加速提示」补发一次探针核实，判死权全留心跳（防降级红线）。

**技术栈：** Swift 6 / Swift Concurrency（actor、@MainActor、structured concurrency）、SwiftUI、XCTest（iOS）、swift-testing（`@Test`，RelayProtocol/relay-server）、SwiftNIO（relay-dialout）、SPM + Xcode 工程混合。

## 全局约束（Global Constraints）

每个任务的要求都隐含包含本节。取值逐字复制自 Design Doc 与项目铁律：

- **移植类文件铁律：** 以当前 master（base-ref `27f47185`）版本为基线**只叠加 delta**，**禁止**从 #45 分支整文件覆盖（否则带回 #46 已删的 SSH 字段/类型、撤销 #46）。参考 #45 时只取其逻辑 diff。
- **安全·防降级红线（构造性证明）：** relay 是不可信中间人。`.peerLeft` → 仅 `probeOnce()` → 唯有端到端心跳超时才 `onUnhealthy → triggerReconnect`；心跳仍回响则忽略。判死权全留心跳，恶意/故障 relay 不得凭空杀健康连接。
- **安全·零知识不破坏：** `RelaySignal` 仅承载连接层事件（`kind`+`sessionId`），relay-server 只转发信令，iPad/dev 试解后 `continue`/`return`，绝不进入 E2E 明文解析路径。
- **安全·fail-closed：** 心跳判死、传输断开一律推入可见异常 phase，不 fail-open 假装在线。
- **安全·不动密码学：** 不改 E2E 原语/握手契约，**不 bump `RelayProtocolVersion.tag`**（心跳纯活在已建立 E2E 信道内）。
- **能耗·前后台门控：** 心跳前台 10s 周期；转后台 `setForeground(false)` 取消 loop，回前台重启 + 补发一次。
- **能耗·重连有界：** 判死重连复用既有指数退避（封顶 30s、最多 6 次），不无界重试；无空转（仅 `.ready` 活跃连接上运行心跳）。
- **UI 恒定原则：** 横竖屏 + 软键盘/外接键盘下横幅与灰点均正确。
- **心跳默认值：** `interval = .seconds(10)`、`missThreshold = 2`；判死延迟 ≈ 20–30s（用户已确认沿用既定行为）。
- **pbxproj：** 新增 iOS 源 + 测试文件必须注册进 `project.pbxproj` 的 PBXBuildFile / PBXFileReference / 对应 group / Sources build phase 四处；`RelaySignal` 在 SPM 包由 Package.swift 自动纳入，**不进 pbxproj**。
- **丢弃项（用户确认「SSH 相关都不要」）：** 不移植 #45 的 `ProxyChannel.swift` SSH 掉线改动、不移植 `ProxyChannelControlTests.swift`、不为 relay 补等价「主动掉线信号」。

### 移植基线核查结论（已逐文件验证）

- 缺失文件（干净加）：`packages/RelayProtocol/Sources/RelayProtocol/RelaySignal.swift`、`ios/CodexRemote/Stores/HeartbeatMonitor.swift`。
- 已存在且**已注册** pbxproj 的测试文件（本计划仅**追加** #45 新增用例，不改 pbxproj）：`RelayReconnectTests.swift`、`TabIndicatorTests.swift`、`ConnectionStoreTests.swift`、`RelayRoomTests.swift`（relay-server SPM 自动纳入）。
- 需**新增并注册** pbxproj 的 iOS 文件：`HeartbeatMonitor.swift`（源）、`HeartbeatMonitorTests.swift`、`ConnectionBannerStateTests.swift`、`JSONRPCClientHeartbeatCorrelationTests.swift`。
- `ProxyChannel*` 在当前 master `project.pbxproj` 中 **0 引用**（#46 已彻底移除）——#45 pbxproj 里「用 `ProxyChannelControlTests` 换 `ReconnectOutboundQueueTests`」的改动**整体作废、不移植**。
- 全部结构锚点已确认存在：ConnectionStore（`phase` private(set)、`needsRePairing`、`foregroundActive`、`AnyCodable`、`RPCMethod.getAuthStatus`、`observeControl`、`.trustRevoked`）；RelayTransport（`ws`、`activeClose`、`channelFactory`、`controlStream`、`SecureEnvelope(decoding:)`、`emitControl`）；RelayRoom（`Slot{connId, sink}`、`typealias Sink`、`leave(sessionId:role:connId:)`）；dialout（`import RelayProtocol`、`RejectHello`、`context.hellos` 握手分支）；测试 harness（`LoopbackRelayWSChannel.inject()` 在 `RelayTestHarness.swift:96`）。

### pbxproj 处理策略（对 tasks.md 顺序的合理偏移）

tasks.md 把「pbxproj 注册」列在靠后。但 iOS 走 TDD 需要**测试文件先能编译进 target 才能 red-green**，故本计划把「pbxproj 注册」**折叠进各新文件的创建任务**（skill 明确允许把 scaffolding 折进需要它的任务），并在验收任务（Task 14）做一次 pbxproj 完整性审计。

### 通用验证命令

- RelayProtocol：`cd /Volumes/mount/codex-for-pados/packages/RelayProtocol && swift test`
- relay-server：`cd /Volumes/mount/codex-for-pados/relay-server && swift test`
- relay-dialout：`cd /Volumes/mount/codex-for-pados/relay-dialout && swift test`
- iOS（单测试类）：`cd /Volumes/mount/codex-for-pados/ios && xcodebuild test -scheme CodexRemote -destination 'platform=iOS Simulator,name=iPad-Test' -derivedDataPath DerivedData -only-testing:CodexRemoteTests/<TestClass>`
- iOS（全量）：同上去掉 `-only-testing`。

archived-with: 2026-08-04-land-connection-health
---

## Task 1: RelaySignal 连接层信号帧（协议层，干净加）

**对应 tasks.md：** 1.1 + 1.2（协议层 RelayProtocol）

**Files:**
- Create: `packages/RelayProtocol/Sources/RelayProtocol/RelaySignal.swift`
- Test: `packages/RelayProtocol/Tests/RelayProtocolTests/RelaySignalTests.swift`（Create）
- （无需改 Package.swift：SPM 自动纳入 `Sources/`、`Tests/` 下的文件）

**Interfaces:**
- Produces：`public struct RelaySignal: Codable, Sendable, Equatable { public var kind: String; public var sessionId: String; public static let peerLeftKind = "peer-left"; public init(kind:sessionId:); public func encoded() throws -> Data; public init(decoding: Data) throws }`。供 RelayTransport（Task 6）、ConnectionStore、relay-server（Task 12）、relay-dialout（Task 13）消费。

**测试先行要点（TDD）：** 先写往返编解码断言 + 「与无 `kind` 的 `SecureEnvelope` 试解歧义」双向断言（这是靠 `kind` 字段做帧类型消歧的构造性证明）。`tag` 未变断言：确认 `RelayProtocolVersion.tag` 无改动（本任务不碰它，断言其当前值即可）。

- [ ] **Step 1: 写失败测试** `RelaySignalTests.swift`

```swift
import Testing
import Foundation
@testable import RelayProtocol

@Test func relaySignalRoundTrips() throws {
    let s = RelaySignal(kind: RelaySignal.peerLeftKind, sessionId: "sess-1")
    let decoded = try RelaySignal(decoding: try s.encoded())
    #expect(decoded == s)
    #expect(decoded.kind == "peer-left")
}

// 关键：peer-left 信号与 SecureEnvelope 必须能靠「有无 kind 字段」互相区分（试解歧义）。
@Test func relaySignalDisambiguatesFromSecureEnvelope() throws {
    let sig = try RelaySignal(kind: RelaySignal.peerLeftKind, sessionId: "s").encoded()
    let env = SecureEnvelope(v: 1, sessionId: "s", keyEpoch: 0, sender: .devMachine,
                             counter: 1, ciphertext: Data([1]), tag: Data([2]))
    let envData = try env.encoded()
    #expect((try? RelaySignal(decoding: envData)) == nil)   // 缺 kind → 解不出 signal
    #expect((try? SecureEnvelope(decoding: sig)) == nil)    // 缺 sender/counter → 解不出 envelope
}
```

> 若 `SecureEnvelope(v:sessionId:keyEpoch:sender:counter:ciphertext:tag:)` 的初始化签名与上不符，以 master 当前 `SecureEnvelope` 定义为准调整构造参数（本步只为拿一个「无 kind」的对照样本）。

- [ ] **Step 2: 运行确认失败**

Run: `cd /Volumes/mount/codex-for-pados/packages/RelayProtocol && swift test --filter RelaySignal`
Expected: 编译失败（`cannot find 'RelaySignal'`）。

- [ ] **Step 3: 写最小实现** `RelaySignal.swift`

```swift
import Foundation

/// 连接层信号帧（非 E2E）。由 relay-server 在一端离开时向仍在的对端明文下发，
/// 供接收端作「加速提示」。零知识不破：仅承载连接层事件，绝不含会话内容。
/// 靠 `kind` 字段与无 `kind` 的 `SecureEnvelope` 试解歧义（仿 `RejectHello`）。
/// 不进 HKDF/握手，不 bump `RelayProtocolVersion.tag`。
public struct RelaySignal: Codable, Sendable, Equatable {
    public var kind: String
    public var sessionId: String

    /// 「对端已离开」信号的 kind 常量。
    public static let peerLeftKind = "peer-left"

    public init(kind: String, sessionId: String) {
        self.kind = kind
        self.sessionId = sessionId
    }

    public func encoded() throws -> Data { try JSONEncoder().encode(self) }
    public init(decoding data: Data) throws {
        self = try JSONDecoder().decode(RelaySignal.self, from: data)
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `cd /Volumes/mount/codex-for-pados/packages/RelayProtocol && swift test`
Expected: 全绿（含既有用例）。

- [ ] **Step 5: 提交**

```bash
cd /Volumes/mount/codex-for-pados
git add packages/RelayProtocol/Sources/RelayProtocol/RelaySignal.swift packages/RelayProtocol/Tests/RelayProtocolTests/RelaySignalTests.swift
git commit -m "feat(relay-proto): add RelaySignal connection-layer frame (peer-left)"
```

同步 tasks.md：勾选 1.1、1.2。

archived-with: 2026-08-04-land-connection-health
---

## Task 2: HeartbeatMonitor 端到端心跳调度器（iOS，干净加）

**对应 tasks.md：** 2.1 + 2.2（iOS 心跳核心）

**Files:**
- Create: `ios/CodexRemote/Stores/HeartbeatMonitor.swift`
- Test: `ios/CodexRemoteTests/HeartbeatMonitorTests.swift`（Create）
- Modify: `ios/CodexRemote.xcodeproj/project.pbxproj`（注册上述 2 文件：源入 Stores group + CodexRemote Sources phase；测试入 Tests group + CodexRemoteTests Sources phase）

**Interfaces:**
- Produces：`@MainActor final class HeartbeatMonitor`，`struct Config: Sendable { var interval: Duration = .seconds(10); var missThreshold: Int = 2 }`，`init(config:probe:onUnhealthy:sleep:)`（`probe: @escaping @Sendable () async -> Bool`、`onUnhealthy: @escaping @Sendable () async -> Void`、`sleep: @escaping @Sendable (Duration) async -> Void` 默认 `Task.sleep`），`func start()`、`func stop()`、`func setForeground(_:)`、`func probeOnce() async`。供 ConnectionStore（Task 7）消费。

**测试先行要点（TDD）：** 用注入的脚本化 `probe`（`ResultScript`）+ no-op `sleep`（`Task.yield()`）驱动纯调度逻辑，脱离真时钟。覆盖：连续 2 次错过判死、单次错过不判死、后台暂停、`probeOnce` miss 判死 / hit 忽略、判死后 `start()` 重启循环、回前台重启+补发。

- [ ] **Step 1: 写失败测试** `HeartbeatMonitorTests.swift`（完整移植 #45，末尾含 `ResultScript`/`Counter` actor + `waitUntil`）

```swift
import XCTest
@testable import CodexRemote

@MainActor
final class HeartbeatMonitorTests: XCTestCase {
    func test_twoConsecutiveMisses_triggersUnhealthy() async throws {
        let results = ResultScript([true, false, true, false, false])  // 第 4、5 次连续 miss
        let counter = Counter()
        let m = HeartbeatMonitor(
            config: .init(interval: .seconds(10), missThreshold: 2),
            probe: { await results.next() },
            onUnhealthy: { await counter.increment() },
            sleep: { _ in await Task.yield() })
        m.start()
        try await waitUntil { await results.consumed >= 5 }
        m.stop()
        let unhealthy = await counter.value
        XCTAssertEqual(unhealthy, 1, "仅在连续 2 次 miss 时判死一次，单次 miss 不判死")
    }

    func test_background_pausesProbes() async throws {
        let results = ResultScript(Array(repeating: true, count: 100))
        let m = HeartbeatMonitor(config: .init(interval: .seconds(10), missThreshold: 2),
                                 probe: { await results.next() },
                                 onUnhealthy: {}, sleep: { _ in await Task.yield() })
        m.start()
        try await waitUntil { await results.consumed >= 1 }
        m.setForeground(false)
        let snapshot = await results.consumed
        try? await Task.sleep(for: .milliseconds(50))
        let afterPause = await results.consumed
        XCTAssertEqual(afterPause, snapshot, "后台不再消耗探针")
    }

    func test_probeOnce_singleMiss_triggersUnhealthy() async {
        let counter = Counter()
        let m = HeartbeatMonitor(config: .init(), probe: { false },
                                 onUnhealthy: { await counter.increment() }, sleep: { _ in })
        await m.probeOnce()
        let unhealthy = await counter.value
        XCTAssertEqual(unhealthy, 1)
    }

    func test_probeOnce_hit_ignored() async {
        let counter = Counter()
        let m = HeartbeatMonitor(config: .init(), probe: { true },
                                 onUnhealthy: { await counter.increment() }, sleep: { _ in })
        await m.probeOnce()
        let unhealthy = await counter.value
        XCTAssertEqual(unhealthy, 0)
    }

    func test_afterDeath_start_resumesLoop() async throws {
        let results = ResultScript(Array(repeating: false, count: 200))  // 恒 miss
        let m = HeartbeatMonitor(config: .init(interval: .seconds(10), missThreshold: 2),
                                 probe: { await results.next() },
                                 onUnhealthy: {}, sleep: { _ in await Task.yield() })
        m.start()
        try await waitUntil { await results.consumed >= 2 }
        let atDeath = await results.consumed
        m.start()
        try await waitUntil { await results.consumed > atDeath }
        m.stop()
        let resumed = await results.consumed
        XCTAssertGreaterThan(resumed, atDeath, "判死后 start() 应重启探测循环")
    }

    func test_foregroundResume_restartsLoopAndProbesOnce() async throws {
        let results = ResultScript(Array(repeating: true, count: 200))
        let m = HeartbeatMonitor(config: .init(interval: .seconds(10), missThreshold: 2),
                                 probe: { await results.next() },
                                 onUnhealthy: {}, sleep: { _ in await Task.yield() })
        m.start()
        try await waitUntil { await results.consumed >= 1 }
        m.setForeground(false)
        try? await Task.sleep(for: .milliseconds(20))
        let paused = await results.consumed
        m.setForeground(true)
        try await waitUntil { await results.consumed > paused }
        m.stop()
        let afterResume = await results.consumed
        XCTAssertGreaterThan(afterResume, paused, "回前台应恢复循环并补发探针")
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("waitUntil 超时")
    }
}

actor ResultScript {
    private var queue: [Bool]; private(set) var consumed = 0
    init(_ r: [Bool]) { queue = r }
    func next() -> Bool { consumed += 1; return queue.isEmpty ? true : queue.removeFirst() }
}

actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}
```

> 注意：`ResultScript` / `Counter` 为全局 actor，避免与既有测试文件重名冲突。若 `CodexRemoteTests` 内已存在同名类型（现无），改用本文件私有嵌套类型。

- [ ] **Step 2: 注册 pbxproj 并运行确认失败**

先按「pbxproj 处理策略」把 `HeartbeatMonitor.swift`（Stores group + CodexRemote Sources phase）与 `HeartbeatMonitorTests.swift`（Tests group + CodexRemoteTests Sources phase）各新增 PBXFileReference + PBXBuildFile + group 成员 + Sources 引用（共 4 处/文件，参照 #45 pbxproj diff 的 `HeartbeatMonitor` / `HeartbeatMonitorTests` 条目，用工程内唯一的 24 位十六进制 ID）。
Run: `cd /Volumes/mount/codex-for-pados/ios && xcodebuild test -scheme CodexRemote -destination 'platform=iOS Simulator,name=iPad-Test' -derivedDataPath DerivedData -only-testing:CodexRemoteTests/HeartbeatMonitorTests`
Expected: 编译失败（`cannot find 'HeartbeatMonitor'`）。

- [ ] **Step 3: 写最小实现** `HeartbeatMonitor.swift`

```swift
import Foundation

/// app 级端到端心跳调度器（design D1/D5）。
/// 纯调度 + 连续错过计数 + 前后台门控；探针本体（getAuthStatus 往返 + 单次超时）由外部注入。
/// 判活只看「有无回响」，天然跨登录方式。
@MainActor
final class HeartbeatMonitor {
    struct Config: Sendable {
        var interval: Duration = .seconds(10)
        var missThreshold: Int = 2
    }

    private let config: Config
    private let probe: @Sendable () async -> Bool
    private let onUnhealthy: @Sendable () async -> Void
    private let sleep: @Sendable (Duration) async -> Void

    private var loopTask: Task<Void, Never>?
    private var consecutiveMisses = 0
    private var foreground = true
    private var started = false

    init(config: Config = .init(),
         probe: @escaping @Sendable () async -> Bool,
         onUnhealthy: @escaping @Sendable () async -> Void,
         sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.config = config
        self.probe = probe
        self.onUnhealthy = onUnhealthy
        self.sleep = sleep
    }

    func start() {
        started = true
        consecutiveMisses = 0
        restartLoopIfNeeded()
    }

    func stop() {
        started = false
        loopTask?.cancel()
        loopTask = nil
        consecutiveMisses = 0
    }

    func setForeground(_ active: Bool) {
        foreground = active
        if active {
            restartLoopIfNeeded()
            Task { await probeOnce() }   // 回前台立即补发一次
        } else {
            loopTask?.cancel()           // 后台暂停：不维持前台级唤醒
            loopTask = nil
        }
    }

    /// 带外单次探活（peer-left 核实）：未回响即判死，有回响忽略。
    func probeOnce() async {
        let ok = await probe()
        if !ok { await onUnhealthy() }
    }

    private func restartLoopIfNeeded() {
        guard started, foreground, loopTask == nil else { return }
        loopTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let ok = await self.probe()
                if Task.isCancelled { return }
                if ok {
                    self.consecutiveMisses = 0
                } else {
                    self.consecutiveMisses += 1
                    if self.consecutiveMisses >= self.config.missThreshold {
                        self.consecutiveMisses = 0
                        self.loopTask = nil   // 释放句柄，使 start()/回前台可经 restartLoopIfNeeded 重启
                        await self.onUnhealthy()
                        return
                    }
                }
                await self.sleep(self.config.interval)
            }
        }
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: 同 Step 2 的 xcodebuild test 命令。
Expected: `HeartbeatMonitorTests` 6 个用例全绿。

- [ ] **Step 5: 提交**

```bash
cd /Volumes/mount/codex-for-pados
git add ios/CodexRemote/Stores/HeartbeatMonitor.swift ios/CodexRemoteTests/HeartbeatMonitorTests.swift ios/CodexRemote.xcodeproj/project.pbxproj
git commit -m "feat(ios): add HeartbeatMonitor end-to-end heartbeat scheduler"
```

同步 tasks.md：勾选 2.1、2.2。

archived-with: 2026-08-04-land-connection-health
---

## Task 3: JSON-RPC id 关联刻画测试（心跳载体校验）

**对应 tasks.md：** 2.3（心跳载体校验：`getAuthStatus` 无冗余 ping + JSON-RPC id 关联）

**Files:**
- Test: `ios/CodexRemoteTests/JSONRPCClientHeartbeatCorrelationTests.swift`（Create）
- Modify: `ios/CodexRemote.xcodeproj/project.pbxproj`（注册该测试文件）

**Interfaces:**
- Consumes：既有 `MockTransport`、`JSONRPCClient(transport:)`、`client.start()`、`client.send(method:params:)`、`RPCMethod.getAuthStatus`、`AnyCodable`、`MockTransport.sent`/`feed(_:)`（均在 master 现存）。
- Produces：无生产接口，纯刻画测试——证明「发一个 `getAuthStatus`、按其 JSON-RPC id 收回响」即可复用作心跳，无需新增冗余 ping RPC。

**测试先行要点（TDD）：** 本任务是「测试即交付物」，无实现代码——它锁定心跳探针复用既有 RPC 关联机制的前提。若测试因 `MockTransport` API 差异不过，调整测试适配 master 的 mock，不得新增 ping RPC。

- [ ] **Step 1: 写测试** `JSONRPCClientHeartbeatCorrelationTests.swift`

```swift
import XCTest
@testable import CodexRemote

/// 心跳前置刻画（design §1.2）：确认 JSONRPCClient.send(method:params:) 已按 JSON-RPC id
/// 关联请求-响应，可直接复用作端到端心跳（发 getAuthStatus、按其 id 收回响）。
final class JSONRPCClientHeartbeatCorrelationTests: XCTestCase {
    func test_send_awaitsResponseById() async throws {
        let mock = MockTransport()
        let client = JSONRPCClient(transport: mock)
        await client.start()
        let empty = try JSONDecoder().decode(AnyCodable.self, from: Data("{}".utf8))

        let probe = Task { try await client.send(method: RPCMethod.getAuthStatus, params: empty) }
        try await waitUntil { await !mock.sent.isEmpty }
        let sentText = await mock.sent[0]
        let id = try Self.extractId(from: sentText)
        await mock.feed(#"{"jsonrpc":"2.0","id":\#(id),"result":{}}"#)

        _ = try await probe.value   // 不抛 = 按 id 成功关联回响
    }

    private static func extractId(from json: String) throws -> String {
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        if let n = obj["id"] as? NSNumber { return n.stringValue }
        return "\"\(obj["id"] as! String)\""
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("waitUntil 超时")
    }
}
```

> 若 master 的 `MockTransport` 无 `sent`/`feed(_:)`（现有 `ControlEmittingTransport` 等 mock 具备类似能力），以 master 现存 mock API 为准调整——目标不变：取出 send 的 id、喂同 id response、`send` 返回即通过。

- [ ] **Step 2: 注册 pbxproj + 运行确认（先失败后通过）**

注册 `JSONRPCClientHeartbeatCorrelationTests.swift`（Tests group + CodexRemoteTests Sources phase）。
Run: `cd /Volumes/mount/codex-for-pados/ios && xcodebuild test -scheme CodexRemote -destination 'platform=iOS Simulator,name=iPad-Test' -derivedDataPath DerivedData -only-testing:CodexRemoteTests/JSONRPCClientHeartbeatCorrelationTests`
Expected: 通过（若 API 不符先失败，按上注调整测试至通过）。

- [ ] **Step 3: 提交**

```bash
cd /Volumes/mount/codex-for-pados
git add ios/CodexRemoteTests/JSONRPCClientHeartbeatCorrelationTests.swift ios/CodexRemote.xcodeproj/project.pbxproj
git commit -m "test(ios): characterize JSON-RPC id correlation for heartbeat reuse"
```

同步 tasks.md：勾选 2.3。

archived-with: 2026-08-04-land-connection-health
---

## Task 4: TransportControlEvent 新增 .peerLeft（传输层，语义移植）

**对应 tasks.md：** 3.1

**Files:**
- Modify: `ios/CodexRemote/Transport/TransportControlEvent.swift`

**Interfaces:**
- Produces：`enum TransportControlEvent` 新增 `case peerLeft`。供 RelayTransport（Task 6）、ConnectionStore observeControl（Task 7）、RelayReconnectTests（Task 6）、ConnectionStoreTests（Task 7）消费。

**测试先行要点（TDD）：** 该枚举的行为测试落在 Task 6（`testPeerLeftFrameEmitsPeerLeftControlWithoutDisconnect`）与 Task 7（`test_peerLeft_*`）。本任务是枚举扩容的先决 case，单独提交以隔离编译面。

- [ ] **Step 1: 加 case**（在 `.trustRevoked` 之后追加，不动既有 case 顺序）

```swift
    case trustRevoked      // 收到 RejectHello（信任被撤销）= 终态（引导重新配对）
    case peerLeft          // relay 连接层「对端已离开」提示（非判决：iPad 收到后补发心跳核实）
```

- [ ] **Step 2: 编译确认**

Run: `cd /Volumes/mount/codex-for-pados/ios && xcodebuild build -scheme CodexRemote -destination 'platform=iOS Simulator,name=iPad-Test' -derivedDataPath DerivedData`
Expected: 编译通过（因 `TransportControlEvent` 消费点用 `switch` 且现有点未穷尽处理 `.peerLeft`，若报未穷尽——那属正常，将在 Task 6/7 补分支；此处若 build 因未穷尽而失败，先跳过 build 校验，待 Task 6/7 补齐后统一 green）。

> 说明：`.peerLeft` 的所有 `switch` 消费点（RelayTransport emitControl 侧不 switch、ConnectionStore.observeControl 需补 `case .peerLeft`）在 Task 7 补齐。为保持单任务可编译，可将本任务与 Task 7 的 observeControl 分支合并提交时机——但推荐仍独立提交枚举 case，Task 7 紧随其后。

- [ ] **Step 3: 提交**

```bash
cd /Volumes/mount/codex-for-pados
git add ios/CodexRemote/Transport/TransportControlEvent.swift
git commit -m "feat(ios): add .peerLeft transport control event"
```

同步 tasks.md：勾选 3.1。

archived-with: 2026-08-04-land-connection-health
---

## Task 5: MessageTransport.triggerReconnect 默认实现（传输层，语义移植）

**对应 tasks.md：** 3.2（控制信号通道默认实现，relay-only 语境）

**Files:**
- Modify: `ios/CodexRemote/Transport/MessageTransport.swift`

**Interfaces:**
- Produces：`protocol MessageTransport` 新增 `func triggerReconnect() async`，`extension MessageTransport` 提供默认空实现（no-op）。供 ConnectionStore.startHeartbeat（Task 7）调用、RelayTransport（Task 6）覆写、`ControlEmittingTransport`（Task 7 测试）覆写计数。

**测试先行要点（TDD）：** 默认 no-op 的行为由 Task 7 的 `ControlEmittingTransport.triggerReconnect()` 覆写计数间接验证；本任务是协议扩容，随 Task 6/7 的测试一起 green。移植时注意 #45 注释提到 `ProxyChannel`——**去掉 SSH 表述**，改写为「无内部重连能力的 transport（MockTransport 等）为 no-op」。

- [ ] **Step 1: 加协议方法 + 默认实现**

协议体内（`setForeground` 之后）加：

```swift
    /// 心跳判死后主动触发一次内部有界重连（默认无重连能力的 transport 为 no-op）。
    func triggerReconnect() async
```

extension 内（`setForeground` 默认实现之后）加（**去 SSH 表述**）：

```swift
    /// 默认：无内部重连能力的 transport（MockTransport 等）为 no-op。
    /// 具备有界重连的 transport（RelayTransport）可覆写以主动丢弃当前通道触发重连。
    func triggerReconnect() async { }
```

> #45 原注释含「ProxyChannel」，本 change relay-only，删除该词。

- [ ] **Step 2: 编译确认**

Run: `cd /Volumes/mount/codex-for-pados/ios && xcodebuild build -scheme CodexRemote -destination 'platform=iOS Simulator,name=iPad-Test' -derivedDataPath DerivedData`
Expected: 编译通过（默认实现使所有既有 conformer 自动满足）。

- [ ] **Step 3: 提交**

```bash
cd /Volumes/mount/codex-for-pados
git add ios/CodexRemote/Transport/MessageTransport.swift
git commit -m "feat(ios): add MessageTransport.triggerReconnect with default no-op"
```

同步 tasks.md：勾选 3.2。

archived-with: 2026-08-04-land-connection-health
---

## Task 6: RelayTransport peer-left 试解 + triggerReconnect（传输层，语义移植）

**对应 tasks.md：** 3.3 + 3.4

**Files:**
- Modify: `ios/CodexRemote/Transport/RelayTransport.swift`
- Test: `ios/CodexRemoteTests/RelayReconnectTests.swift`（**追加** 2 个 #45 新用例，文件已存在且已注册 pbxproj）

**Interfaces:**
- Consumes：`RelaySignal`（Task 1）、`.peerLeft`（Task 4）、`triggerReconnect`（Task 5 协议方法）、既有 `emitControl(_:)`、`ws`、`activeClose`、`channelFactory`、`reconnectLoop`/`handleDisconnect(nil)` 链路、`SecureEnvelope(decoding:)`、测试 harness `LoopbackRelayWSChannel.inject()`（`RelayTestHarness.swift:96`）。
- Produces：`RelayTransport.triggerReconnect()` 覆写；接收循环对 peer-left 帧 `emitControl(.peerLeft); continue`。

**测试先行要点（TDD）：** 先追加两个失败测试——(a) 向当前回环通道 `inject` 一个 peer-left 明文帧 → 断言收到 `.peerLeft` 控制事件且**不断开、不重连**（业务往返仍活、`connectCount` 不增）；(b) `triggerReconnect()` → 断言发 `.reconnecting` 再 `.ready`、`connectCount` 增（复用既有 `reconnectLoop`）。

- [ ] **Step 1: 追加失败测试到 `RelayReconnectTests.swift`**（在 class 尾 `}` 前插入）

```swift
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
```

> 依赖 `RelayReconnectTests.swift` 内已有的 `ReconnectScript` / `makeTransport` / `RelayReconnectPolicy` / `LoopbackRelayWSChannel`（master 现存）。`import RelayProtocol` 已在文件头。

- [ ] **Step 2: 运行确认失败**

Run: `cd /Volumes/mount/codex-for-pados/ios && xcodebuild test -scheme CodexRemote -destination 'platform=iOS Simulator,name=iPad-Test' -derivedDataPath DerivedData -only-testing:CodexRemoteTests/RelayReconnectTests`
Expected: 新 2 用例失败（peer-left 帧当前会走 `SecureEnvelope(decoding:)` 解密失败路径；`triggerReconnect` 默认 no-op 不触发重连）。

- [ ] **Step 3: 实现——接收循环加 peer-left 试解分支**

在 `RelayTransport.swift` 接收循环中、`let env = try SecureEnvelope(decoding: Data(frame.utf8))` **之前**插入：

```swift
                // 连接层信号（relay peer-left）：不解密、不断开、不重连，仅上报提示事件。
                // 靠 `kind` 字段与无 `kind` 的 SecureEnvelope 试解歧义（业务密文帧无 kind，解不成 RelaySignal）。
                if let sig = try? RelaySignal(decoding: Data(frame.utf8)),
                   sig.kind == RelaySignal.peerLeftKind {
                    emitControl(.peerLeft)
                    continue
                }
```

- [ ] **Step 4: 实现——覆写 triggerReconnect**

在 `func control()` 之后（与 #45 同位）加：

```swift
    /// 心跳判死后主动触发一次内部有界重连：丢弃当前 ws 通道使读循环 receiveText() 返回 nil，
    /// 因**未置** activeClose 且 channelFactory != nil，handleDisconnect(nil) 会走 reconnectLoop()
    /// （发 .reconnecting → 复用既有退避/上限路径），与自然瞬断走同一链路。
    func triggerReconnect() async {
        await ws?.close()
    }
```

- [ ] **Step 5: 运行确认通过**

Run: 同 Step 2。
Expected: `RelayReconnectTests` 全绿（含既有重连/退避/后台暂停用例 + 新 2 用例）。

- [ ] **Step 6: 提交**

```bash
cd /Volumes/mount/codex-for-pados
git add ios/CodexRemote/Transport/RelayTransport.swift ios/CodexRemoteTests/RelayReconnectTests.swift
git commit -m "feat(ios): RelayTransport peer-left passthrough + triggerReconnect"
```

同步 tasks.md：勾选 3.3、3.4。

archived-with: 2026-08-04-land-connection-health
---

## Task 7: ConnectionStore 集成心跳（连接状态与集成，语义移植——最重）

**对应 tasks.md：** 4.1 + 4.4

**Files:**
- Modify: `ios/CodexRemote/Stores/ConnectionStore.swift`
- Test: `ios/CodexRemoteTests/ConnectionStoreTests.swift`（**追加** 3 个 #45 用例 + 扩展 `ControlEmittingTransport`，文件已存在且已注册）

**Interfaces:**
- Consumes：`HeartbeatMonitor`（Task 2）、`.peerLeft`（Task 4）、`MessageTransport.triggerReconnect`（Task 5）、既有 `rpc.send(method:params:)`、`RPCMethod.getAuthStatus`、`AnyCodable`、`observeControl`、`phase`/`needsRePairing`/`foregroundActive`、`connect(config:)`、`applyForeground(_:)`。
- Produces：`struct HeartbeatUnhealthy: Sendable { let run: @Sendable () async -> Void }`；`ConnectionStore.init` 新增 `heartbeatFactory:` 可选参数；`func reconnect()`；`enum ConnectionBannerState: Equatable { case reconnecting, failed, trustRevoked }`；`var bannerState: ConnectionBannerState?`；`#if DEBUG` 的 `_test_setPhase(_:)` / `_test_setTrustRevoked()`。供 Task 8（SessionsManager 不直接依赖）、Task 9（App banner 用 `bannerState` + `reconnect()` + `showRePairing`）、Task 11（ConnectionBannerStateTests 用 `bannerState` + `_test_*`）消费。

**测试先行要点（TDD）：** 3 个集成测试——(a) 心跳判死（注入恒 miss monitor）→ `triggerReconnect` 被调 ≥1；(b) peer-left + 探针 miss → `triggerReconnect` ≥1；(c) **防降级红线**：peer-left + 探针 hit → `triggerReconnect==0` 且 phase 保持 `.ready`。用 `heartbeatFactory` 注入脚本化 `HeartbeatMonitor`；扩展 `ControlEmittingTransport` 加 `triggerReconnectCount` 计数 + `emitControl(.peerLeft)`。

- [ ] **Step 1: 追加失败测试 + 扩展 mock** 到 `ConnectionStoreTests.swift`

在 class 内插入 3 个测试（`feedInitializeResponse` / `.stub` / `waitUntil` 均为文件内既有工具）：

```swift
    func test_heartbeatDeath_triggersReconnect() async throws {
        let mock = ControlEmittingTransport()
        let store = await ConnectionStore(
            transportFactory: { _ in mock },
            heartbeatFactory: { cb in
                HeartbeatMonitor(config: .init(interval: .milliseconds(1), missThreshold: 2),
                                 probe: { false }, onUnhealthy: cb.run,
                                 sleep: { _ in await Task.yield() }) })
        await feedInitializeResponse(mock)
        await store.connect(config: .stub)
        try await waitUntil { if case .ready = await store.phase { return true }; return false }
        try await waitUntil { await mock.triggerReconnectCount >= 1 }
        let count = await mock.triggerReconnectCount
        XCTAssertGreaterThanOrEqual(count, 1, "连续错过 2 次应触发一次有界重连")
    }

    func test_peerLeft_probeMiss_triggersReconnect() async throws {
        let mock = ControlEmittingTransport()
        let store = await ConnectionStore(
            transportFactory: { _ in mock },
            heartbeatFactory: { cb in
                HeartbeatMonitor(config: .init(interval: .milliseconds(1), missThreshold: 2),
                                 probe: { false }, onUnhealthy: cb.run,
                                 sleep: { _ in await Task.yield() }) })
        await feedInitializeResponse(mock)
        await store.connect(config: .stub)
        try await waitUntil { if case .ready = await store.phase { return true }; return false }
        await mock.emitControl(.peerLeft)
        try await waitUntil { await mock.triggerReconnectCount >= 1 }
        let count = await mock.triggerReconnectCount
        XCTAssertGreaterThanOrEqual(count, 1, "peer-left 后探针 miss 应判死并触发重连")
    }

    func test_peerLeft_probeHit_ignored_staysReady() async throws {
        let mock = ControlEmittingTransport()
        let store = await ConnectionStore(
            transportFactory: { _ in mock },
            heartbeatFactory: { cb in
                HeartbeatMonitor(config: .init(interval: .milliseconds(1), missThreshold: 2),
                                 probe: { true }, onUnhealthy: cb.run,
                                 sleep: { _ in await Task.yield() }) })
        await feedInitializeResponse(mock)
        await store.connect(config: .stub)
        try await waitUntil { if case .ready = await store.phase { return true }; return false }
        await mock.emitControl(.peerLeft)
        try? await Task.sleep(nanoseconds: 50_000_000)
        let count = await mock.triggerReconnectCount
        XCTAssertEqual(count, 0, "健康时收到伪造 peer-left 不得判死")
        if case .ready = await store.phase {} else { XCTFail("应保持 .ready，实际 \(await store.phase)") }
    }
```

扩展既有 `actor ControlEmittingTransport`（加计数属性 + 覆写 + 确认有 `emitControl`）：

```swift
    private(set) var triggerReconnectCount = 0
    func triggerReconnect() async { triggerReconnectCount += 1 }
```

> 若 `ControlEmittingTransport` 尚无 `emitControl(_:)` 公开方法，补一个把事件推入其 control continuation 的方法（master 该 mock 已用于 `.reconnecting` 接线测试，通常已具备发事件能力，按现有 API 命名对齐）。

- [ ] **Step 2: 运行确认失败**

Run: `cd /Volumes/mount/codex-for-pados/ios && xcodebuild test -scheme CodexRemote -destination 'platform=iOS Simulator,name=iPad-Test' -derivedDataPath DerivedData -only-testing:CodexRemoteTests/ConnectionStoreTests`
Expected: 新 3 用例失败（`heartbeatFactory` 参数不存在、心跳未接线）。

- [ ] **Step 3: 实现 ConnectionStore delta**（逐处叠加，**基于 relay-only 当前版本**）

3a. `ConnectionConfig` 定义后加逃逸包装类型：

```swift
struct HeartbeatUnhealthy: Sendable {
    let run: @Sendable () async -> Void
}
```

3b. 字段区（`config` 附近）加：

```swift
    private var lastConfig: ConnectionConfig?
    private var heartbeat: HeartbeatMonitor?
    private let injectedHeartbeatFactory: (@MainActor (HeartbeatUnhealthy) -> HeartbeatMonitor)?
```

3c. `init` 增参 + 存储：

```swift
    init(transportFactory: @escaping @Sendable (ConnectionConfig) async throws -> MessageTransport,
         connectTimeoutNanos: UInt64 = 20_000_000_000,
         heartbeatFactory: (@MainActor (HeartbeatUnhealthy) -> HeartbeatMonitor)? = nil) {
        self.transportFactory = transportFactory
        self.connectTimeoutNanos = connectTimeoutNanos
        self.injectedHeartbeatFactory = heartbeatFactory
    }
```

3d. `connect(config:)` 里 `self.config = config` 之后加 `self.lastConfig = config`。

3e. 首连成功落 `.ready` 处（`self.isReady = true` 之后、`observeControl` 之前）加 `self.startHeartbeat()`。

3f. `disconnect()` 开头 `activeAttempt += 1` 之后加 `stopHeartbeat()`。

3g. `applyForeground(active)` 里：后台转 `.disconnected` 分支加 `stopHeartbeat()`；方法尾加 `heartbeat?.setForeground(active)`。

3h. 新增心跳方法区（`observeControl` 之前）：

```swift
    // MARK: - 端到端心跳

    func reconnect() {
        if let c = lastConfig { connect(config: c) }
    }

    private func sendHeartbeatProbe() async -> Bool {
        guard let rpc else { return false }
        guard let empty = try? JSONDecoder().decode(AnyCodable.self, from: Data("{}".utf8)) else { return false }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { (try? await rpc.send(method: RPCMethod.getAuthStatus, params: empty)) != nil }
            group.addTask { try? await Task.sleep(nanoseconds: 10_000_000_000); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    private func makeRealHeartbeat(onUnhealthy: @escaping @Sendable () async -> Void) -> HeartbeatMonitor {
        HeartbeatMonitor(probe: { [weak self] in await self?.sendHeartbeatProbe() ?? false },
                         onUnhealthy: onUnhealthy)
    }

    private func startHeartbeat() {
        heartbeat?.stop()
        let onUnhealthy: @Sendable () async -> Void = { [weak self] in
            await self?.transport?.triggerReconnect()
        }
        let m = injectedHeartbeatFactory?(HeartbeatUnhealthy(run: onUnhealthy))
            ?? makeRealHeartbeat(onUnhealthy: onUnhealthy)
        m.setForeground(foregroundActive)
        m.start()
        heartbeat = m
    }

    private func stopHeartbeat() {
        heartbeat?.stop()
        heartbeat = nil
    }
```

> `rpc.send(method:params:)` / `RPCMethod.getAuthStatus` / `AnyCodable` 均为 master 现存符号。若 `rpc.send` 的确切签名不同（如 label 差异），对齐 master 现有调用点（参考 `EnvironmentInspectorModel.swift` 的 getAuthStatus 用法）。

3i. `observeControl` 的 switch 各分支叠加心跳启停 + 新增 `.peerLeft` 分支：

```swift
                case .reconnecting:
                    self.phase = .reconnecting
                    self.stopHeartbeat()   // 离开 .ready：停心跳，重连成功后再起
                    // ...（保留 master 既有 failInflight 逻辑不动）
                case .ready:
                    self.phase = .ready
                    self.startHeartbeat()  // 物理重连成功：重启心跳
                    if let h = self.resumeHandler { await h() }
                case .connectionFailed:
                    self.stopHeartbeat()
                    self.phase = .failed("连接失败，请稍后重试")
                case .trustRevoked:
                    self.stopHeartbeat()
                    self.phase = .failed("已被开发机移除信任，请重新配对")
                    self.needsRePairing = true
                case .peerLeft:
                    // 非判决（防降级红线）：不改 phase、不断开、不重连，只补发一次心跳核实。
                    if let hb = self.heartbeat { Task { await hb.probeOnce() } }
```

> **移植铁律：** 上面各 case 里，除新增行外，**保留 master 版本原有语句**（尤其 `.reconnecting` 里的 in-flight 请求失败处理、`.ready`/`.connectionFailed`/`.trustRevoked` 的既有文案/副作用）。只做「叠加」。

3j. 文件尾加 banner 态 + DEBUG 测试钩子：

```swift
/// 连接异常横幅态（缺口 3、4）。隐藏为 nil。
/// 信任撤销（needsRePairing）优先于普通 failed。
enum ConnectionBannerState: Equatable {
    case reconnecting
    case failed
    case trustRevoked
}

extension ConnectionStore {
    var bannerState: ConnectionBannerState? {
        if needsRePairing { return .trustRevoked }
        switch phase {
        case .reconnecting: return .reconnecting
        case .failed:       return .failed
        default:            return nil
        }
    }
}

#if DEBUG
extension ConnectionStore {
    func _test_setPhase(_ p: ConnectionPhase) { phase = p }
    func _test_setTrustRevoked() { phase = .failed("trust"); needsRePairing = true }
}
#endif
```

- [ ] **Step 4: 运行确认通过**

Run: 同 Step 2。
Expected: `ConnectionStoreTests` 全绿（含既有用例 + 新 3 用例；防降级用例 `test_peerLeft_probeHit_ignored_staysReady` 通过 = 红线守住）。

- [ ] **Step 5: 提交**

```bash
cd /Volumes/mount/codex-for-pados
git add ios/CodexRemote/Stores/ConnectionStore.swift ios/CodexRemoteTests/ConnectionStoreTests.swift
git commit -m "feat(ios): integrate heartbeat + peer-left verification into ConnectionStore"
```

同步 tasks.md：勾选 4.1、4.4。

archived-with: 2026-08-04-land-connection-health
---

## Task 8: TabIndicator + TabBarView 灰点（UI，语义移植）

**对应 tasks.md：** 5.2 + 5.4（TabIndicator 部分）

> **顺序说明：** 本任务先于 Task 9（SessionsManager），因 `SessionsManager.indicator()` 返回 `.disconnected` 依赖本 case 存在。

**Files:**
- Modify: `ios/CodexRemote/Domain/TabIndicator.swift`
- Modify: `ios/CodexRemote/Views/TabBarView.swift`
- Test: `ios/CodexRemoteTests/TabIndicatorTests.swift`（**追加** 3 个 #45 用例，文件已存在且已注册）

**Interfaces:**
- Produces：`enum TabIndicator` 新增 `case disconnected`（`isBlinking == false`）；`TabBarView.DotView` 新增 `.disconnected → dot(.gray)`。供 Task 9 `SessionsManager.indicator()` 消费。
- Consumes：既有 `TabIndicator.resolve(isConnected:statuses:hasUnread:)`、`isBlinking`、`DotView.dot(_:)`。

**测试先行要点（TDD）：** 追加 3 断言——`disconnected.isBlinking == false`（红橙闪与灰点严格正交）、`resolve(isConnected:false,[.systemError]) == .none`（红点不在未连接时产生，灰点由上层给）、`resolve(isConnected:true,[.systemError]) == .error`。

- [ ] **Step 1: 追加失败测试** 到 `TabIndicatorTests.swift`（class 尾 `}` 前）

```swift
    // 灰点 disconnected 非闪烁（与 error/attention 红橙闪严格区分）。
    func test_disconnectedCaseNotBlinking() {
        XCTAssertFalse(TabIndicator.disconnected.isBlinking)
    }
    // 红灰正交：resolve 仅在 connected 时判 systemError；未连接不产生红点。
    func test_notConnected_resolveStillNone_grayIsLayeredAbove() {
        XCTAssertEqual(TabIndicator.resolve(isConnected: false, statuses: [.systemError]), .none)
    }
    func test_connectedSystemError_red() {
        XCTAssertEqual(TabIndicator.resolve(isConnected: true, statuses: [.systemError]), .error)
    }
```

- [ ] **Step 2: 运行确认失败**

Run: `cd /Volumes/mount/codex-for-pados/ios && xcodebuild test -scheme CodexRemote -destination 'platform=iOS Simulator,name=iPad-Test' -derivedDataPath DerivedData -only-testing:CodexRemoteTests/TabIndicatorTests`
Expected: `test_disconnectedCaseNotBlinking` 编译失败（`disconnected` 不存在）。

- [ ] **Step 3: 实现——TabIndicator 加 case**

```swift
enum TabIndicator: Equatable {
    case none, unread, running, attention, error, disconnected

    // disconnected（灰点，连接异常）非闪烁：与 error/attention（红橙闪）严格正交。
    var isBlinking: Bool { self == .attention || self == .error }
    // ...（resolve 等既有实现保持不动）
}
```

- [ ] **Step 4: 实现——TabBarView.DotView 加映射**

在 `DotView` 的 switch 中 `.error` 之后加：

```swift
            case .disconnected: dot(.gray)   // 连接异常灰点，非闪烁
```

- [ ] **Step 5: 运行确认通过**

Run: 同 Step 2。
Expected: `TabIndicatorTests` 全绿。

- [ ] **Step 6: 提交**

```bash
cd /Volumes/mount/codex-for-pados
git add ios/CodexRemote/Domain/TabIndicator.swift ios/CodexRemote/Views/TabBarView.swift ios/CodexRemoteTests/TabIndicatorTests.swift
git commit -m "feat(ios): add disconnected gray tab indicator (orthogonal to error red)"
```

同步 tasks.md：勾选 5.2、5.4（TabIndicator 部分）。

archived-with: 2026-08-04-land-connection-health
---

## Task 9: SessionsManager 断线态接线（连接状态与集成，语义移植）

**对应 tasks.md：** 4.2

**Files:**
- Modify: `ios/CodexRemote/Stores/SessionsManager.swift`
- Test: 复用既有 `SessionsManagerTests`（如无对应断言，靠 Task 8 的 `TabIndicatorTests` + 编译保证；本任务改动小且被 UI 集成覆盖）。

**Interfaces:**
- Consumes：`TabIndicator.disconnected`（Task 8）、`s.connection.phase`、`TabIndicator.resolve(isConnected:statuses:hasUnread:)`。
- Produces：`indicator(for:)` 在「已建 Session 但 `phase != .ready`」时返回 `.disconnected`；`.ready` 前提下才评估会话状态（红灰严格正交）。

**测试先行要点（TDD）：** 红灰正交语义已由 Task 8 的 `TabIndicatorTests` 覆盖（resolve 层）。本任务改的是上层聚合：若存在 `SessionsManagerTests`，加一条「已建 Session 且 phase=.reconnecting → indicator == .disconnected」；否则以编译 + 现有测试回归为准，并在 Task 14 的模拟器验收目视确认灰点。

- [ ] **Step 1（可选，若有 SessionsManagerTests 基建）: 写断言**

```swift
    // 已建 Session 但连接非就绪 → 灰点。
    func test_indicator_notReady_isDisconnected() { /* 构造 cache[id] 且 phase=.reconnecting → 断言 .disconnected */ }
```

- [ ] **Step 2: 实现 `indicator(for:)` delta**

```swift
    func indicator(for id: UUID) -> TabIndicator {
        guard let s = cache[id] else { return .none }   // 未建 Session（懒连未连）→ 无点
        // 已建但连接非就绪 → 灰点。红灰正交：灰点在此上层给出，
        // resolve 仅在 .ready 前提下评估会话状态（红点仅由 systemError 在已连接时触发）。
        guard s.connection.phase == .ready else { return .disconnected }
        let statuses = s.projects.allThreadsSorted.compactMap { s.projects.status(of: $0.id) }
        let hasUnread = s.projects.allThreadsSorted.contains { s.projects.hasUnread($0, isSelected: false) }
        return TabIndicator.resolve(isConnected: true, statuses: statuses, hasUnread: hasUnread)
    }
```

- [ ] **Step 3: 运行回归**

Run: `cd /Volumes/mount/codex-for-pados/ios && xcodebuild test -scheme CodexRemote -destination 'platform=iOS Simulator,name=iPad-Test' -derivedDataPath DerivedData -only-testing:CodexRemoteTests/SessionsManagerTests`
Expected: 全绿（无回归）。

- [ ] **Step 4: 提交**

```bash
cd /Volumes/mount/codex-for-pados
git add ios/CodexRemote/Stores/SessionsManager.swift ios/CodexRemoteTests/SessionsManagerTests.swift
git commit -m "feat(ios): SessionsManager returns .disconnected when session not ready"
```

同步 tasks.md：勾选 4.2。

archived-with: 2026-08-04-land-connection-health
---

## Task 10: 断线横幅三态 + 重新配对入口 + 文案本地化（UI，语义移植）

**对应 tasks.md：** 4.3 + 5.1 + 5.3

**Files:**
- Modify: `ios/CodexRemote/App/CodexRemoteApp.swift`
- Modify: `ios/CodexRemote/Resources/Localizable.xcstrings`

**Interfaces:**
- Consumes：`connection.bannerState`（Task 7）、`connection.reconnect()`（Task 7）、既有 `RelayPairingImportView`（master 现存，依赖 `@Environment(SessionsManager)`，由 app 根注入）、既有 `RootSplitView`、`.overlay(alignment:.top)`。
- Produces：`WorkspaceHost.reconnectBanner`（三态）、`@State showRePairing`、`.sheet { NavigationStack { RelayPairingImportView() } }`、私有 `bannerLabel(_:tint:)`。

**测试先行要点（TDD）：** 横幅态映射逻辑测试在 Task 11（`ConnectionBannerStateTests`，测 `bannerState`）。本任务是 SwiftUI 视图接线，无单测；正确性靠 Task 11 的映射测试 + Task 14 模拟器目视（横竖屏/软键盘/外接键盘三态横幅）。**前后台门控挂载**（tasks.md 4.3）已由 Task 7 的 `ConnectionStore.applyForeground → heartbeat?.setForeground` 完成，App 侧既有 scenePhase→applyForeground 接线不变，本任务不重复挂载。

- [ ] **Step 1: 加 xcstrings 4 条文案**（在 `Localizable.xcstrings` 的 `strings` 字典内按 key 字母序插入）

```json
    "connection.disconnected": { "localizations": {
        "en":      { "stringUnit": { "state": "translated", "value": "Disconnected" } },
        "zh-Hans": { "stringUnit": { "state": "translated", "value": "连接已断开" } } } },
    "connection.rePair": { "localizations": {
        "en":      { "stringUnit": { "state": "translated", "value": "Re-pair" } },
        "zh-Hans": { "stringUnit": { "state": "translated", "value": "重新配对" } } } },
    "connection.reconnect": { "localizations": {
        "en":      { "stringUnit": { "state": "translated", "value": "Reconnect" } },
        "zh-Hans": { "stringUnit": { "state": "translated", "value": "重新连接" } } } },
    "connection.trustRevoked": { "localizations": {
        "en":      { "stringUnit": { "state": "translated", "value": "Trust revoked" } },
        "zh-Hans": { "stringUnit": { "state": "translated", "value": "信任已失效" } } } },
```

> 保持 JSON 合法（逗号、缩进对齐既有条目）。`root.reconnecting`（重连中黄条）文案 master 已有，复用不新增。

- [ ] **Step 2: 改 `WorkspaceHost`——加 sheet 状态 + 三态横幅**

字段区加 `@State private var showRePairing = false`。`RootSplitView()` 链上 `.overlay(alignment:.top){ reconnectBanner }` 之后加：

```swift
            .sheet(isPresented: $showRePairing) {
                NavigationStack { RelayPairingImportView() }
            }
```

替换既有单态 `reconnectBanner`（原仅判 `.reconnecting`）为三态：

```swift
    @ViewBuilder private var reconnectBanner: some View {
        switch connection.bannerState {
        case .reconnecting:
            bannerLabel("root.reconnecting", tint: .yellow)
        case .failed:
            HStack(spacing: 8) {
                bannerLabel("connection.disconnected", tint: .red)
                Button("connection.reconnect") { connection.reconnect() }
                    .font(.callout.bold())
            }
            .padding(.top, 8)
        case .trustRevoked:
            HStack(spacing: 8) {
                bannerLabel("connection.trustRevoked", tint: .red)
                Button("connection.rePair") { showRePairing = true }
                    .font(.callout.bold())
            }
            .padding(.top, 8)
        case .none:
            EmptyView()
        }
    }

    private func bannerLabel(_ key: LocalizedStringKey, tint: Color) -> some View {
        Text(key)
            .font(.callout)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(tint.opacity(0.3), in: Capsule())
            .padding(.top, 8)
    }
```

> `connection` 在 `WorkspaceHost` 是 `@Environment(ConnectionStore)` 或等价（master 现有引用，`connection.phase == .reconnecting` 旧代码即证其可达）。保留 master 既有的 `.task(id:)` coordinator 接线不动。

- [ ] **Step 3: 编译 + 运行回归**

Run: `cd /Volumes/mount/codex-for-pados/ios && xcodebuild test -scheme CodexRemote -destination 'platform=iOS Simulator,name=iPad-Test' -derivedDataPath DerivedData -only-testing:CodexRemoteTests/ConnectionStoreTests`
Expected: 编译通过、无回归（横幅态逻辑测试在 Task 11）。

- [ ] **Step 4: 提交**

```bash
cd /Volumes/mount/codex-for-pados
git add ios/CodexRemote/App/CodexRemoteApp.swift ios/CodexRemote/Resources/Localizable.xcstrings
git commit -m "feat(ios): three-state reconnect banner + re-pairing entry + i18n"
```

同步 tasks.md：勾选 4.3、5.1、5.3。

archived-with: 2026-08-04-land-connection-health
---

## Task 11: ConnectionBannerStateTests（UI 映射测试，新增）

**对应 tasks.md：** 5.4（ConnectionBannerState 部分）

**Files:**
- Test: `ios/CodexRemoteTests/ConnectionBannerStateTests.swift`（Create）
- Modify: `ios/CodexRemote.xcodeproj/project.pbxproj`（注册该测试文件）

**Interfaces:**
- Consumes：`ConnectionStore(transportFactory:)`、`bannerState`、`_test_setPhase(_:)`、`_test_setTrustRevoked()`（均 Task 7 产出）、既有 `MockTransport`。

**测试先行要点（TDD）：** 校验 `bannerState` 三态映射 + `needsRePairing` 优先于普通 `failed` + 其余 phase 隐藏（nil）。纯逻辑，`@MainActor`。

- [ ] **Step 1: 写测试** `ConnectionBannerStateTests.swift`

```swift
import XCTest
@testable import CodexRemote

@MainActor
final class ConnectionBannerStateTests: XCTestCase {
    private func store() -> ConnectionStore { ConnectionStore(transportFactory: { _ in MockTransport() }) }

    func test_ready_hidesBanner() async { let s = store(); s._test_setPhase(.ready); XCTAssertNil(s.bannerState) }
    func test_reconnecting_yellow() async { let s = store(); s._test_setPhase(.reconnecting); XCTAssertEqual(s.bannerState, .reconnecting) }
    func test_failed_red() async { let s = store(); s._test_setPhase(.failed("x")); XCTAssertEqual(s.bannerState, .failed) }
    func test_trustRevoked_beatsFailed() async { let s = store(); s._test_setTrustRevoked(); XCTAssertEqual(s.bannerState, .trustRevoked) }
    func test_initializing_hidesBanner() async { let s = store(); s._test_setPhase(.initializing); XCTAssertNil(s.bannerState) }
    func test_connecting_hidesBanner() async { let s = store(); s._test_setPhase(.connecting); XCTAssertNil(s.bannerState) }
    func test_disconnected_hidesBanner() async { let s = store(); s._test_setPhase(.disconnected); XCTAssertNil(s.bannerState) }
}
```

- [ ] **Step 2: 注册 pbxproj + 运行确认失败**

注册 `ConnectionBannerStateTests.swift`（Tests group + CodexRemoteTests Sources phase）。
Run: `cd /Volumes/mount/codex-for-pados/ios && xcodebuild test -scheme CodexRemote -destination 'platform=iOS Simulator,name=iPad-Test' -derivedDataPath DerivedData -only-testing:CodexRemoteTests/ConnectionBannerStateTests`
Expected: 若 Task 7 已实现 `bannerState`/`_test_*` 则直接通过；否则先失败。

- [ ] **Step 3: 运行确认通过**

Run: 同 Step 2。
Expected: 7 用例全绿（`test_trustRevoked_beatsFailed` = 信任撤销优先）。

- [ ] **Step 4: 提交**

```bash
cd /Volumes/mount/codex-for-pados
git add ios/CodexRemoteTests/ConnectionBannerStateTests.swift ios/CodexRemote.xcodeproj/project.pbxproj
git commit -m "test(ios): ConnectionBannerState three-state mapping"
```

同步 tasks.md：勾选 5.4（ConnectionBannerState 部分）。

archived-with: 2026-08-04-land-connection-health
---

## Task 12: relay-server RelayRoom leave 发 peer-left（relay 两端，语义移植）

**对应 tasks.md：** 6.1 + 6.2

**Files:**
- Modify: `relay-server/Sources/RelayServerCore/RelayRoom.swift`
- Test: `relay-server/Tests/RelayServerCoreTests/RelayRoomTests.swift`（**追加** 3 个 #45 用例，SPM 自动纳入）

**Interfaces:**
- Consumes：`RelaySignal`（Task 1，`import RelayProtocol` 已在文件）、既有 `Slot{connId, sink}`、`Room{ipad, dev}`、`leave(sessionId:role:connId:)`、`lock`。
- Produces：`leave` 在某槽被实际清除且另一槽仍在时，**解锁后**向仍在的对端 sink 下发 `RelaySignal(peerLeftKind, sessionId)` JSON。

**测试先行要点（TDD）：** 追加——dev 离开通知 iPad（对端收 1 条 peer-left、离开端不收）、iPad 离开对称通知 dev、迟到重复 leave 不再通知（幂等/防抖）。断言 sink 收到的 JSON 解回 `RelaySignal` 且 `kind==peerLeftKind`、`sessionId` 正确。

- [ ] **Step 1: 追加失败测试** 到 `RelayRoomTests.swift`

```swift
// 缺口 2：一端离开 → 通知仍在的对端（连接层 peer-left 信号）。
@Test func leaveNotifiesRemainingPeer() throws {
    let rooms = RelayRooms()
    var ipadRx: [String] = [], devRx: [String] = []
    guard case let .joined(devId) = rooms.join(sessionId: "s", role: .devMachine, sink: { devRx.append($0) }),
          case .joined = rooms.join(sessionId: "s", role: .iPad, sink: { ipadRx.append($0) }) else {
        return #expect(Bool(false))
    }
    rooms.leave(sessionId: "s", role: .devMachine, connId: devId)
    #expect(ipadRx.count == 1)
    let sig = try RelaySignal(decoding: Data(ipadRx[0].utf8))
    #expect(sig.kind == RelaySignal.peerLeftKind && sig.sessionId == "s")
    #expect(devRx.isEmpty)
}

// 对称：iPad 离开 → 通知 dev。
@Test func leaveNotifiesDevWhenIpadLeaves() throws {
    let rooms = RelayRooms()
    var devRx: [String] = []
    rooms.join(sessionId: "s", role: .devMachine) { devRx.append($0) }
    guard case let .joined(ipadId) = rooms.join(sessionId: "s", role: .iPad, sink: { _ in }) else {
        return #expect(Bool(false))
    }
    rooms.leave(sessionId: "s", role: .iPad, connId: ipadId)
    #expect(devRx.count == 1)
    #expect((try RelaySignal(decoding: Data(devRx[0].utf8))).kind == RelaySignal.peerLeftKind)
}

// 幂等：旧 connId 的迟到 leave 未清任何槽 → 不发通知。
@Test func staleLeaveDoesNotNotify() {
    let rooms = RelayRooms()
    var devRx: [String] = []
    rooms.join(sessionId: "s", role: .devMachine) { devRx.append($0) }
    guard case let .joined(ipadId) = rooms.join(sessionId: "s", role: .iPad, sink: { _ in }) else {
        return #expect(Bool(false))
    }
    rooms.leave(sessionId: "s", role: .iPad, connId: ipadId)
    rooms.leave(sessionId: "s", role: .iPad, connId: ipadId)   // 迟到重复：槽已空
    #expect(devRx.count == 1)
}
```

> 若 `join` 的 sink 参数标签/`JoinResult` case 名与上不符，以 master 现有 `RelayRoomTests.swift` 既有用例的调用风格对齐。

- [ ] **Step 2: 运行确认失败**

Run: `cd /Volumes/mount/codex-for-pados/relay-server && swift test --filter RelayRoom`
Expected: 3 新用例失败（当前 leave 不发通知）。

- [ ] **Step 3: 实现——重写 `leave`（解锁后回调 sink）**

```swift
    /// 清除某 role 的槽(连接断开时用)。仅当槽 connId 与传入一致才清。两端都空则回收房间。
    /// 缺口 2：当某槽被实际清除且另一槽仍在时，向仍在的对端下发连接层 peer-left 信号（不含 E2E 明文）。
    public func leave(sessionId: String, role: RelayPeer, connId: UUID) {
        lock.lock()
        var notifySink: Sink? = nil
        if var room = rooms[sessionId] {
            var removed = false
            switch role {
            case .iPad: if room.ipad?.connId == connId { room.ipad = nil; removed = true }
            case .devMachine: if room.dev?.connId == connId { room.dev = nil; removed = true }
            }
            if room.ipad == nil && room.dev == nil {
                rooms[sessionId] = nil
            } else {
                rooms[sessionId] = room
                if removed { notifySink = room.ipad?.sink ?? room.dev?.sink }   // 仍在的对端
            }
        }
        lock.unlock()
        // 解锁后再回调 sink（sink 内部 hop 到 eventLoop，不同步重入 rooms）。
        if let sink = notifySink,
           let json = try? String(decoding: RelaySignal(kind: RelaySignal.peerLeftKind,
                                                         sessionId: sessionId).encoded(), as: UTF8.self) {
            sink(json)
        }
    }
```

> **零知识：** 只发 `RelaySignal` 信令，绝不碰任何密文/明文会话内容。

- [ ] **Step 4: 运行确认通过**

Run: `cd /Volumes/mount/codex-for-pados/relay-server && swift test`
Expected: 全绿（含既有 `staleLeaveByOldConnIdDoesNotEvictNewer` 等 + 新 3 用例）。

- [ ] **Step 5: 提交**

```bash
cd /Volumes/mount/codex-for-pados
git add relay-server/Sources/RelayServerCore/RelayRoom.swift relay-server/Tests/RelayServerCoreTests/RelayRoomTests.swift
git commit -m "feat(relay-server): notify remaining peer with peer-left on leave (zero-knowledge)"
```

同步 tasks.md：勾选 6.1、6.2。

archived-with: 2026-08-04-land-connection-health
---

## Task 13: relay-dialout 优雅忽略 peer-left（relay 两端，语义移植）

**对应 tasks.md：** 6.3

**Files:**
- Modify: `relay-dialout/Sources/relay-dialout/main.swift`

**Interfaces:**
- Consumes：`RelaySignal`（Task 1，`import RelayProtocol` 已在 `main.swift:7`）、既有 `DialoutWSHandler.channelRead` 握手分支（`if context.hellos != nil` 前，`main.swift:180` 附近）、既有解码出的帧 `Data`（当前实现里的入站数据变量）。
- Produces：dev 侧收到 `kind == peerLeftKind` 的帧时静默 `return`（不据此动作，避免误入握手解析）。

**测试先行要点（TDD）：** relay-dialout 无独立单测覆盖此路径的既有基建时，以「不崩溃 + 编译 + 四端全测」回归为准（design §7 relay-dialout 覆盖=优雅忽略）。若存在可注入帧的测试基建则加一条「喂 peer-left 帧后 handler 不进握手解析、不抛错」。核心是 fail-safe：解不出 RelaySignal 就继续既有握手路径。

- [ ] **Step 1: 实现——握手分支前插入忽略**

在 `DialoutWSHandler.channelRead` 里、`if context.hellos != nil {` 之前插入（`data` 用当前实现里已解出的入站 `Data` 变量名，若不同则对齐）：

```swift
        // 连接层信号（如 relay 的 peer-left）：dev 侧不据此动作，静默忽略，避免误入握手解析。
        if let sig = try? RelaySignal(decoding: data), sig.kind == RelaySignal.peerLeftKind {
            return
        }
```

> 放在既有「先试 ClientAuth 再试 ClientHello」握手解析**之前**，确保 peer-left 帧不被误当握手消息。

- [ ] **Step 2: 编译 + 测试回归**

Run: `cd /Volumes/mount/codex-for-pados/relay-dialout && swift test`
Expected: 编译通过、全绿（无回归）。

- [ ] **Step 3: 提交**

```bash
cd /Volumes/mount/codex-for-pados
git add relay-dialout/Sources/relay-dialout/main.swift
git commit -m "feat(relay-dialout): gracefully ignore peer-left signal on dev side"
```

同步 tasks.md：勾选 6.3。

archived-with: 2026-08-04-land-connection-health
---

## Task 14: spec 修正、四端验收、安全/能耗回归、UI 适配（收口）

**对应 tasks.md：** 7.1 – 7.5 + 5.5（UI 适配基线验收）

**Files:**
- 确认: `openspec/changes/land-connection-health/specs/ipad-connection-health/spec.md`（delta 已就位，MODIFY「所有传输断线均推入可见异常态」为 relay-only，保留原 Requirement 标题只改内容）
- 审计: `ios/CodexRemote.xcodeproj/project.pbxproj`（确认 4 个新文件全注册、无遗漏、无 `ProxyChannel*` 残留引用）

**测试先行要点（TDD）：** 本任务是全链路验证——不写新实现，只跑全量 + 逐条核对铁律用例。

- [ ] **Step 1: pbxproj 完整性审计**

Run:
```bash
cd /Volumes/mount/codex-for-pados
for n in HeartbeatMonitor HeartbeatMonitorTests ConnectionBannerStateTests JSONRPCClientHeartbeatCorrelationTests; do
  echo "$n : $(grep -c "$n" ios/CodexRemote.xcodeproj/project.pbxproj) refs"; done
grep -c "ProxyChannel" ios/CodexRemote.xcodeproj/project.pbxproj
```
Expected: `HeartbeatMonitor` 有 fileRef+buildFile+group+Sources 引用（源 4 refs、各测试 4 refs）；`ProxyChannel` = 0。

- [ ] **Step 2: 四端全量测试全绿**（tasks.md 7.2）

Run（依次）:
```bash
cd /Volumes/mount/codex-for-pados/packages/RelayProtocol && swift test
cd /Volumes/mount/codex-for-pados/relay-server && swift test
cd /Volumes/mount/codex-for-pados/relay-dialout && swift test
cd /Volumes/mount/codex-for-pados/ios && xcodebuild test -scheme CodexRemote -destination 'platform=iOS Simulator,name=iPad-Test' -derivedDataPath DerivedData
```
Expected: 四端全绿。

- [ ] **Step 3: 安全回归——防降级红线**（tasks.md 7.3）

确认 `ConnectionStoreTests.test_peerLeft_probeHit_ignored_staysReady`（伪造 peer-left + 心跳回响 → 保持 `.ready`、`triggerReconnect==0`）与 `RelayReconnectTests.testPeerLeftFrameEmitsPeerLeftControlWithoutDisconnect`（peer-left 不触发重连）通过。
Run: `cd /Volumes/mount/codex-for-pados/ios && xcodebuild test -scheme CodexRemote -destination 'platform=iOS Simulator,name=iPad-Test' -derivedDataPath DerivedData -only-testing:CodexRemoteTests/ConnectionStoreTests/test_peerLeft_probeHit_ignored_staysReady -only-testing:CodexRemoteTests/RelayReconnectTests/testPeerLeftFrameEmitsPeerLeftControlWithoutDisconnect`
Expected: 通过。另确认 `RelayProtocolVersion.tag` 未改（`git diff base-ref -- packages/RelayProtocol | grep -i tag` 应无 tag 值改动）。

- [ ] **Step 4: 能耗回归——后台暂停/回前台恢复**（tasks.md 7.4）

确认 `HeartbeatMonitorTests.test_background_pausesProbes` + `test_foregroundResume_restartsLoopAndProbesOnce` + `RelayReconnectTests.testBackgroundPausesReconnectUntilForeground` 通过（重连有界退避封顶由 `testBackoffReachesCapThenConnectionFailed` 覆盖）。
Run: `cd /Volumes/mount/codex-for-pados/ios && xcodebuild test -scheme CodexRemote -destination 'platform=iOS Simulator,name=iPad-Test' -derivedDataPath DerivedData -only-testing:CodexRemoteTests/HeartbeatMonitorTests`
Expected: 通过。

- [ ] **Step 5: UI 适配基线验收**（tasks.md 5.5——项目恒定原则）

在 `iPad-Test` 模拟器装机启动，目视：横屏 + 竖屏下，断线横幅三态（黄重连中 / 红「重新连接」/ 红「重新配对」）与 tab 灰点均正确显示、按钮可点；软键盘弹出 + 外接键盘态下横幅不被遮挡、布局不错乱。
Run: 参照 build-ops：`xcrun simctl install iPad-Test <.app>` → `xcrun simctl launch iPad-Test com.tangyujie.codexremote` → `xcrun simctl io iPad-Test screenshot /tmp/banner.png`（横竖屏各一张）。
Expected: 三态横幅 + 灰点在四种朝向/键盘组合下均正确。

- [ ] **Step 6: openspec 校验**（tasks.md 7.5）

Run: `cd /Volumes/mount/codex-for-pados && openspec validate land-connection-health --strict`
Expected: PASS。若报「MODIFIED scenario 未继承主 spec 既有 scenario」，按记忆铁律：MODIFIED 整替换须继承主库当前 requirement 全部 scenario，只改内容不改标题（本 delta 已保留原 Requirement 标题 + 2 scenario，若主 spec 有更多 scenario 需逐条补回）。

- [ ] **Step 7: 提交（如有 spec/pbxproj 微调）**

```bash
cd /Volumes/mount/codex-for-pados
git add -A
git commit -m "chore(land-connection-health): spec fixup + four-end verification green"
```

同步 tasks.md：勾选 7.1–7.5、5.5。

archived-with: 2026-08-04-land-connection-health
---

## 自审（Self-Review）

**1. Spec 覆盖**
- delta spec「relay 传输断线推入可见异常态」→ Task 6（RelayTransport 断开→重连）+ Task 7（心跳判死→triggerReconnect→.reconnecting/.failed）。
- delta spec「就绪连接不误判断线」→ Task 7 防降级用例（peer-left + hit → 保持 .ready）。
- 主 spec 既有「对端离开主动通知」→ Task 12（relay-server 发 peer-left）+ Task 13（dialout 忽略）+ Task 6（iPad 收 .peerLeft）+ Task 7（probeOnce 核实）。
- 主 spec 既有「tab 通知指示圆点」灰点 → Task 8（TabIndicator/TabBarView）+ Task 9（SessionsManager）。
- 横幅三态 → Task 10 + Task 11。心跳核心 → Task 2 + Task 3。协议帧 → Task 1。

**2. 占位符扫描：** 无 TBD/TODO；所有 code step 附完整代码；测试代码逐字给出。

**3. 类型一致性：** `RelaySignal.peerLeftKind`、`TransportControlEvent.peerLeft`、`MessageTransport.triggerReconnect()`、`HeartbeatMonitor(config:probe:onUnhealthy:sleep:)`、`HeartbeatUnhealthy.run`、`ConnectionStore.bannerState`/`reconnect()`/`_test_setPhase`/`_test_setTrustRevoked`、`ConnectionBannerState.{reconnecting,failed,trustRevoked}`、`TabIndicator.disconnected` 在定义任务与消费任务间命名一致。

**4. 铁律落点：** 移植只叠加（每个移植任务显式标注「保留 master 既有语句」）；防降级（Task 7 hit 用例 + Task 6 不重连断言）；零知识（Task 12 只发信令）；不 bump tag（Task 1 + Task 14 Step 3 断言）；前后台门控（Task 2 + Task 7）；重连有界（Task 6 复用既有退避）；UI 适配（Task 14 Step 5）；pbxproj 折叠进创建任务 + Task 14 审计；丢弃 ProxyChannel（全局约束 + Task 14 grep=0）。

archived-with: 2026-08-04-land-connection-health
---

## 执行交接

计划已保存到 `docs/superpowers/plans/2026-08-03-land-connection-health.md`。两种执行方式：

1. **Subagent-Driven（推荐）** — 每任务派发独立子代理，任务间两阶段评审，快速迭代（必需子技能 superpowers:subagent-driven-development）。
2. **Inline 执行** — 本会话内用 superpowers:executing-plans 批量执行 + 检查点评审。

选哪种？
