---
change: relay-t5-tail-cleanup
design-doc: docs/superpowers/specs/2026-08-03-relay-t5-tail-cleanup-design.md
base-ref: 97ed4238b08e91d17f927e8be5ce6672344833df
archived-with: 2026-08-03-relay-t5-tail-cleanup
---

# relay-t5-tail-cleanup 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: 用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐 task 实现本计划。步骤用 checkbox（`- [ ]`）语法追踪。

**Goal:** 收敛 T5（relay）历次 review 遗留的尾巴——死代码/陈旧注释、测试硬化、进程与可见性收紧，并把两处「探路期占位」（加密帧类型标签、relay 有界缓冲）升级为正式实现。

**Architecture:** 四端 SwiftPM 单元内改动，不新增跨端接口面。先做低风险机械项（A/B/C）建立四端全绿基线，再做 spec 级行为升级（D，⑥a 加密帧类型 + ⑥d relay 有界缓冲）。每 task 完成即 tasks.md 打勾 + git commit。

**Tech Stack:** Swift 6 / SwiftPM（RelayProtocol、relay-dialout、relay-server 三包）+ Xcode（iOS CodexRemote）；swift-crypto（AES-GCM/Curve25519）、SwiftNIO（relay-server、dialout ws）、Swift Testing（`@Test`）+ XCTest（iOS）。

## Global Constraints

以下为项目级恒定约束，**每个 task 隐含遵守**，逐条 verbatim：

- **代码事实基线 = `origin/master @ 97ed4238b08e91d17f927e8be5ce6672344833df`**。本地 `master @ ef2e9a0b` 是 doc-only 分叉、**缺 SSH 移除合并，绝不可作代码依据**。所有代码事实以 `origin/master` 为准；实现须在**从 `origin/master` 起的 git worktree** 中进行（不是从本地 master）。
- **进程安全铁律（硬约束）**：只操作自己持有的 `process` 句柄（精确 PID），**绝不引入 `pkill` / 宽匹配 / 按名杀**——避免误杀 desktop GUI 私有的 app-server。
- **fail-closed，不 fail-open**：未知/非法/篡改一律拒绝，不回退到任一已知路径、不静默当默认值。
- **零知识不破坏**：relay 只透传/缓存不透明密文帧，任何地方不解析、不解密、不还原 frame 内容。
- **能耗意识**：不新增定时器轮询/常驻空转线程；被动持有、事件驱动；重连/等待有界。
- **app 未上线 → 无线上兼容负担**：帧格式可干净版本化，无存量客户端。
- **DRY / YAGNI / TDD / 频繁提交**：AAD 规范编码收发共用单一实现源；每 task 一次 commit。
- **收尾四端全量测试全绿**：RelayProtocol / relay-dialout / relay-server / iOS CodexRemote，外加 `openspec validate relay-t5-tail-cleanup --strict` 与安全回归。

### 四端测试/构建命令（verbatim，供每个 task 的验证步骤复用）

```bash
# RelayProtocol 包
cd packages/RelayProtocol && swift test

# relay-dialout 包
cd relay-dialout && swift test

# relay-server 包
cd relay-server && swift test

# iOS CodexRemote（唯一可用模拟器名 iPad-Test；首次接 SwiftTerm 需先装 Metal Toolchain）
cd ios && xcodebuild test -scheme CodexRemote \
  -destination 'platform=iOS Simulator,name=iPad-Test' -derivedDataPath DerivedData
```

> 单测过滤：`swift test --filter <TestName>`（Swift Testing 按函数名）；iOS 用 `-only-testing:CodexRemoteTests/<Class>/<method>`。

archived-with: 2026-08-03-relay-t5-tail-cleanup
---

## 文件结构（本计划将创建/修改的文件与职责）

| 文件（相对 repo 根） | 端 | 责任 | 涉及 task |
|---|---|---|---|
| `ios/CodexRemote/Transport/RelayTransport.swift` | iOS | 删占位 `init(ws:)`；`send`/read loop 加 `kind` | 1, 11 |
| `ios/CodexRemote/Security/RelayE2EKeyManager.swift` | iOS | 删 `identityPublicKeyRaw()`；改陈旧注释 | 2, 3 |
| `ios/CodexRemote/App/LiveTransport.swift` | iOS | TOFU 兜底不变量断言 | 6 |
| `ios/CodexRemoteTests/RelayTransportTests.swift` | iOS | `@testable import RelayProtocol`；kind 往返测试 | 8, 11 |
| `relay-dialout/Sources/relay-dialout/main.swift` | dialout | 刷新三处 `TODO(Task 13)` 注释；`seal`/dispatch 加 `kind` | 4, 11 |
| `relay-dialout/Sources/RelayDialoutCore/DialoutContext.swift` | dialout | SecureReady `seal` 加 `kind: .secureReady` | 11 |
| `relay-dialout/Sources/RelayDialoutCore/ProxyBridge.swift` | dialout | `terminate()` 补 `waitUntilExit()` | 7 |
| `relay-dialout/Tests/RelayDialoutCoreTests/DialoutTLSTests.swift` | dialout | 补完整证书校验断言 | 5 |
| `relay-dialout/Tests/RelayDialoutCoreTests/ProxyBridgeTests.swift`（新建） | dialout | `terminate()` 回收 + 仅操作自身句柄 | 7 |
| `packages/RelayProtocol/Sources/RelayProtocol/SecureEnvelope.swift` | RelayProtocol | 增 `RelayFrameKind` + `kind` 字段 + AAD 规范编码 | 9 |
| `packages/RelayProtocol/Sources/RelayProtocol/SecureSession.swift` | RelayProtocol | `seal(_:kind:)`/`open` 传 AAD；`init` 收窄 internal | 9, 10, 8 |
| `packages/RelayProtocol/Tests/RelayProtocolTests/SecureSessionTests.swift` | RelayProtocol | kind 往返/未知拒/篡改 fail-closed 测试 | 10 |
| `relay-server/Sources/RelayServerCore/FrameAccumulator.swift` | relay-server | `RelayLimits` 增缓冲上限常量 | 13 |
| `relay-server/Sources/RelayServerCore/RelayRoom.swift` | relay-server | 每房间有界 FIFO 缓冲 + join flush | 12, 13 |
| `relay-server/Tests/RelayServerCoreTests/RelayRoomTests.swift` | relay-server | 缓冲按序/上限/回收/零知识测试 | 14 |

archived-with: 2026-08-03-relay-t5-tail-cleanup
---

## 前置：worktree 与基线核对

- [ ] **P0: 确认 worktree 从 `origin/master` 起、四端基线全绿**

若尚未在 worktree 中：由执行方按 `superpowers:using-git-worktrees` 从 `origin/master`（`97ed4238`）创建。核对基线：

```bash
git rev-parse HEAD            # 期望：97ed4238…（或从它派生的 worktree 分支 HEAD）
git merge-base --is-ancestor 97ed4238b08e91d17f927e8be5ce6672344833df HEAD && echo "BASE OK"
```

运行四端测试确认起点全绿（命令见上文「四端测试/构建命令」）。Expected：四端全部 PASS。若非全绿，**停止**并先查环境（可能是 worktree 未携带 gitignored `openspec/`+`docs/`，或未装 Metal Toolchain）。

archived-with: 2026-08-03-relay-t5-tail-cleanup
---

## A. 死代码 / 陈旧注释（零行为，tasks.md #1-#4）

> 已用 `git grep origin/master` 核实调用方；删除后靠四端全量测试兜底。风险仅「误删活代码」，本组均已核实零调用方。

### Task 1: 删除 iOS `RelayTransport.init(ws:)` 占位构造（tasks.md #1 / 设计①）

**Files:**
- Modify: `ios/CodexRemote/Transport/RelayTransport.swift`（删除约 `:148-166` 的 `init(ws:)` 及其上方 doc 注释）

**Interfaces:**
- Consumes: 无
- Produces: 无（纯删除；保留 `init(session:ws:)`、`init(channelFactory:...)` 两条构造路径）

- [ ] **Step 1: 核实零调用方**

```bash
git grep -n "RelayTransport(ws" -- 'ios/**/*.swift'   # 期望：零命中（仅定义存在）
git grep -n "init(ws"          -- 'ios/**/*.swift'    # 期望：仅 RelayTransport.swift 定义行
```
Expected：除定义行外零命中。若有命中 → **停止**，该 init 仍活跃，不删。

- [ ] **Step 2: 删除 `init(ws:)`**

删除下述整段（doc 注释 + init 体），位于 `init(session:ws:)` 之后、`init(channelFactory:...)` 之前：

```swift
    /// 占位构造路径：仅给定 ws、无握手输入、无工厂。真 ws 连接与握手编排尚未接入的调用方用它构造；
    /// `awaitHandshake` 会因缺输入落 `.failed`。
    init(ws: RelayWSChannel) {
        self.session = nil
        self.ws = ws
        self.channelFactory = nil
        self.handshakeState = .pending
        self.handshakeInputs = nil
        self.reconnect = RelayReconnectPolicy()
        var inCont: AsyncThrowingStream<String, Error>.Continuation!
        self.incomingStream = AsyncThrowingStream<String, Error>(bufferingPolicy: .unbounded) { inCont = $0 }
        self.incomingContinuation = inCont
        var ctlCont: AsyncStream<TransportControlEvent>.Continuation!
        self.controlStream = AsyncStream<TransportControlEvent>(bufferingPolicy: .unbounded) { ctlCont = $0 }
        self.controlContinuation = ctlCont
    }
```

- [ ] **Step 3: 编译 iOS 验证无引用断裂**

Run（iOS 测试命令，见上）。Expected：编译通过、iOS 全测 PASS（无「init(ws:) 未找到」类错误）。

- [ ] **Step 4: Commit**

```bash
git add ios/CodexRemote/Transport/RelayTransport.swift
git commit -m "refactor(ios): remove dead RelayTransport.init(ws:) placeholder"
```
并在 `openspec/changes/relay-t5-tail-cleanup/tasks.md` 勾选第 1 项。

### Task 2: 删除 iOS `RelayE2EKeyManager.identityPublicKeyRaw()`（tasks.md #2 / 设计②）

**Files:**
- Modify: `ios/CodexRemote/Security/RelayE2EKeyManager.swift`（删 `:59` 方法）

**Interfaces:**
- Consumes: 无
- Produces: 无

> **保留铁律**：只删 iOS 侧这一个方法。dialout `DevKeyStore.identityPublicKeyRaw`（`relay-dialout/.../DevKeyStore.swift:26`）是**另一类型的 `var`**、活跃使用（`main.swift:105` 等），**绝不动**。

- [ ] **Step 1: 核实 iOS 侧零调用方**

```bash
git grep -n "identityPublicKeyRaw" -- 'ios/**/*.swift'
```
Expected：仅 `RelayE2EKeyManager.swift:59` 定义行（iOS 无其它调用者；`LiveTransport.swift` 用的是 `identityKey()`）。若 iOS 出现调用点 → **停止**，不删。

- [ ] **Step 2: 删除方法**

删除：
```swift
    /// 身份公钥 raw（供 ClientHello）。
    func identityPublicKeyRaw() throws -> Data { try identityKey().publicKey.rawRepresentation }
```

- [ ] **Step 3: 编译 iOS 验证**

Run（iOS 测试命令）。Expected：iOS 全测 PASS。

- [ ] **Step 4: Commit**

```bash
git add ios/CodexRemote/Security/RelayE2EKeyManager.swift
git commit -m "refactor(ios): remove unused RelayE2EKeyManager.identityPublicKeyRaw()"
```
勾选 tasks.md 第 2 项。

### Task 3: 修正 `RelayE2EKeyManager.swift` 陈旧注释（tasks.md #3 / 设计③）

**Files:**
- Modify: `ios/CodexRemote/Security/RelayE2EKeyManager.swift:6`

**Interfaces:** 无。

> 事实：`KeyManager.swift` 已随 SSH 移除删除，`KeyStoring` 协议现定义于 `ios/CodexRemote/Security/KeyStoring.swift`。

- [ ] **Step 1: 改注释**

```swift
// old:
/// 复用 KeyManager.swift 定义的 `KeyStoring` 协议（同 target，internal 可见）。
// new:
/// 复用 KeyStoring.swift 定义的 `KeyStoring` 协议（同 target，internal 可见）。
```

- [ ] **Step 2: 编译 iOS 验证**（注释改动，确认无手误破坏文件）

Run（iOS 测试命令）。Expected：iOS 全测 PASS。

- [ ] **Step 3: Commit**

```bash
git add ios/CodexRemote/Security/RelayE2EKeyManager.swift
git commit -m "docs(ios): fix stale KeyStoring protocol reference in RelayE2EKeyManager"
```
勾选 tasks.md 第 3 项。

> Task 2 与 Task 3 改同一文件，可在同一 commit 合并；若分开执行则按上述各自提交。

### Task 4: 刷新 dialout `main.swift` 三处 `TODO(Task 13)` 注释（tasks.md #4 / 设计④）

**Files:**
- Modify: `relay-dialout/Sources/relay-dialout/main.swift`（约 `:22`、`:128`、`:214` 三处过时措辞）

**Interfaces:** 无（纯注释；ws 拨出已落地，`DialoutWSHandler` + 转发测试全绿）。

- [ ] **Step 1: 定位三处**

```bash
git grep -n "Task 13\|尚未接入\|骨架\|本 task 求编译" -- 'relay-dialout/Sources/relay-dialout/main.swift'
```

- [ ] **Step 2: 改写为现状注释**

将「骨架 / 尚未接入 / 本 task 求编译通过 + Task 13 验证」等过时措辞改为反映现状（ws 拨出已实现、转发链路已测）。示例（`:22` 附近顶注）：

```swift
// old:
// 本 task 求编译通过 + 逻辑正确；端到端由 Task 13/真机验证。ws 接线复杂处标注 TODO。
// new:
// ws 客户端拨出 relay 已落地（DialoutWSHandler 收发 + 帧分发已由 RelayDialoutCore 测试覆盖）；端到端由真机验收。
```

`:128` 附近（原 `TODO(Task 13/集成): 下面为 ws 客户端拨出骨架。关键点：…`）改为描述**已实现**的 ws 拨出流程（不再是「骨架/关键点」）。`:214` 的 `/* TODO(集成): 上报启动失败 */` 若仍为真实待办则**保留**（这是真 TODO，不是 Task 13 陈旧措辞）——只清理与「Task 13 尚未接入」相关的过时话术，不虚构已完成的功能。

- [ ] **Step 3: 编译 dialout 验证**

Run: `cd relay-dialout && swift test`。Expected：全测 PASS。

- [ ] **Step 4: Commit**

```bash
git add relay-dialout/Sources/relay-dialout/main.swift
git commit -m "docs(dialout): refresh stale Task 13 comments to reflect shipped ws dialout"
```
勾选 tasks.md 第 4 项。

archived-with: 2026-08-03-relay-t5-tail-cleanup
---

## B. 测试硬化（仅测试，tasks.md #5-#6）

### Task 5: DialoutTLS 完整证书校验断言（tasks.md #5 / 设计⑤a）

**Files:**
- Test: `relay-dialout/Tests/RelayDialoutCoreTests/DialoutTLSTests.swift`（在既有 `clientTLSHandlerBuildsWithDefaultClientConfig` 旁新增断言）

**Interfaces:**
- Consumes: `NIOSSL.TLSConfiguration.makeClientConfiguration()`；`DialoutTLS.makeClientHandler(serverHostname:)`
- Produces: 无

> 设计事实：`DialoutTLS.makeClientHandler` 用 `NIOSSLContext(configuration: .makeClientConfiguration())`，NIOSSL 默认 `certificateVerification == .fullVerification`。断言锁死该不变量，防未来回归成 `.none` / `.noHostnameVerification`。

- [ ] **Step 1: build 阶段先复核实际构造点**

```bash
git grep -n "makeClientConfiguration\|certificateVerification\|NIOSSLClientHandler" -- 'relay-dialout/Sources/RelayDialoutCore/DialoutTLS.swift'
```
确认构造仍为 `.makeClientConfiguration()`。若构造方式已变（如显式设过 `certificateVerification`），**以实际构造点为准**再写断言，避免断言写错反成假绿。

- [ ] **Step 2: 写断言测试**

在 `DialoutTLSTests.swift` 追加：

```swift
import NIOSSL

/// 锁死不变量：拨出客户端 TLS 启用完整证书校验（含主机名）。防回归成 .none / .noHostnameVerification。
@Test func clientTLSUsesFullCertificateVerification() {
    let config = TLSConfiguration.makeClientConfiguration()
    #expect(config.certificateVerification == .fullVerification)
}
```

- [ ] **Step 3: 运行确认通过**

Run: `cd relay-dialout && swift test --filter clientTLSUsesFullCertificateVerification`。Expected：PASS（`.fullVerification` 为 NIOSSL 客户端默认）。

- [ ] **Step 4: Commit**

```bash
git add relay-dialout/Tests/RelayDialoutCoreTests/DialoutTLSTests.swift
git commit -m "test(dialout): assert client TLS uses full certificate verification"
```
勾选 tasks.md 第 5 项。

### Task 6: LiveTransport TOFU 兜底不变量断言（tasks.md #6 / 设计⑤b）

**Files:**
- Modify: `ios/CodexRemote/App/LiveTransport.swift:74`（`liveTransportFactory` 内 `tofuMachineKey: config.relayTOFUKey ?? relayURL`）

**Interfaces:** 无对外面变化。

> 设计事实：`liveTransportFactory` 已保证 `config.relayURL != nil` 才继续；`config.relayTOFUKey` 在正常路径恒非空（`MachineConfig` 构造时置 `id.uuidString`）。`?? relayURL` 兜底在正常路径不可达。补 `assert` 固化契约——**不改运行时行为**（release 下 `assert` 空操作）。

- [ ] **Step 1: 在兜底前补前置断言**

在 `return try await makeRelayTransport(...)` 之前插入：

```swift
    // 不变量：正常路径 relayTOFUKey 恒非空（MachineConfig 构造置 id.uuidString）；?? relayURL 仅为
    // 类型收尾兜底，正常路径不可达。assert 固化契约、防未来回归误走兜底（release 下空操作，不改行为）。
    assert(config.relayTOFUKey != nil, "relayTOFUKey 恒应非空；走 ?? relayURL 兜底说明上游契约被破坏")
```

- [ ] **Step 2: 编译 + iOS 全测验证行为不变**

Run（iOS 测试命令）。Expected：iOS 全测 PASS（现有测试若走此路径均提供了 `relayTOFUKey`，断言不触发）。

- [ ] **Step 3: Commit**

```bash
git add ios/CodexRemote/App/LiveTransport.swift
git commit -m "test(ios): assert relayTOFUKey non-nil invariant in liveTransportFactory"
```
勾选 tasks.md 第 6 项。

archived-with: 2026-08-03-relay-t5-tail-cleanup
---

## C. 进程 / 可见性收紧（局部低风险，tasks.md #7-#8）

### Task 7: `ProxyBridge.terminate()` 补 `waitUntilExit()` 回收子进程（tasks.md #7 / 设计⑥b）

**Files:**
- Modify: `relay-dialout/Sources/RelayDialoutCore/ProxyBridge.swift:83-86`（`terminate()`）
- Test: `relay-dialout/Tests/RelayDialoutCoreTests/ProxyBridgeTests.swift`（新建）

**Interfaces:**
- Consumes: `Foundation.Process`（`isRunning`、`terminate()`、`waitUntilExit()`、`processIdentifier`）
- Produces: `ProxyBridge.terminate()`（回收后返回，无僵尸）；`ProxyBridge.pid: Int32`（已存在，测试用）

> **进程安全铁律**：只对 `ProxyBridge` 自己持有的 `process` 句柄操作（精确 PID），**绝不 `pkill`/宽匹配/按名杀**。既有注释已声明此铁律。
> **能耗**：`waitUntilExit()` 是终止收尾的一次性同步等待（非轮询、非常驻线程）；进程已被 `terminate()` 请求退出，等待即刻返回。

- [ ] **Step 1: 写失败测试——terminate 后进程被回收**

新建 `relay-dialout/Tests/RelayDialoutCoreTests/ProxyBridgeTests.swift`，用无害长驻 stub（`/bin/sleep`）代替真 codex：

```swift
import Testing
import Foundation
@testable import RelayDialoutCore

/// terminate() 应回收子进程（补 waitUntilExit 前，进程会残留为僵尸直到父进程 reap）。
@Test func terminateReapsSpawnedChildNoZombie() throws {
    // 用 /bin/sleep 作无害长驻子进程 stub（codexPath 可注入）。
    let bridge = ProxyBridge(codexPath: "/bin/sleep", sockPath: "/tmp/relay-t5-proxybridge-test.sock")
    // ProxyBridge.start() 固定传 arguments=["app-server","proxy","--sock",sock]；sleep 会忽略并因参数立即退出，
    // 但对「terminate 后 isRunning==false」不变量足够——若需长驻可改注入允许自定义 arguments 的构造（见 Step 3 说明）。
    try bridge.start()
    let pid = bridge.pid
    #expect(pid > 0)                 // 确有自己 spawn 的子进程
    bridge.terminate()
    // terminate 内 waitUntilExit 返回后，进程不再运行（已被 reap，无僵尸）。
    #expect(bridge.pid == pid)       // 仍是同一个自己持有的句柄（未按名/宽匹配另找进程）
}
```

- [ ] **Step 2: 运行确认当前行为（可能已「过」但未 reap）**

Run: `cd relay-dialout && swift test --filter terminateReapsSpawnedChildNoZombie`。
说明：补 `waitUntilExit()` 前，`terminate()` 只发信号不等待——测试可能瞬时通过但子进程短暂成僵尸。本 task 目标是**加回收保证**，以下 Step 3 实现后语义确定。若 stub 因固定 arguments 立即退出导致断言不稳定，改用允许注入 `arguments` 的测试构造（见下）。

- [ ] **Step 3: 实现——`terminate()` 补 `waitUntilExit()`**

```swift
    /// 只停自己 spawn 的这个子进程（精确 PID），绝不 pkill。terminate 后同步等待其退出以回收（无僵尸）。
    public func terminate() {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()   // 回收：等自身 process 句柄退出，防僵尸。仅等自己这一个，非轮询、非按名杀。
        }
    }
```

> 若 Step 1 的 stub 因 `start()` 固定 `arguments` 无法长驻、导致「start 后 isRunning 已 false」使断言不稳：为 `ProxyBridge` 增测试友好的可注入 `arguments`（默认 `["app-server","proxy","--sock",sockPath]`，保持生产行为不变），测试传 `arguments: ["300"]` 让 `/bin/sleep` 长驻，再验 `terminate()` 后回收。此改动**仅扩展默认参数注入点，不改生产调用路径**。

- [ ] **Step 4: 断言未引入宽匹配 kill**

```bash
git grep -n "pkill\|killall\|Process(.*kill\|/usr/bin/kill\|\"kill\"" -- 'relay-dialout/Sources/**/*.swift'
```
Expected：零命中（`terminate()` 仅用 `process.terminate()` + `waitUntilExit()`，只操作自身句柄）。

- [ ] **Step 5: 运行 dialout 全测**

Run: `cd relay-dialout && swift test`。Expected：全测 PASS（含新 ProxyBridgeTests）。

- [ ] **Step 6: Commit**

```bash
git add relay-dialout/Sources/RelayDialoutCore/ProxyBridge.swift \
        relay-dialout/Tests/RelayDialoutCoreTests/ProxyBridgeTests.swift
git commit -m "fix(dialout): reap proxy child in ProxyBridge.terminate via waitUntilExit"
```
勾选 tasks.md 第 7 项。

### Task 8: `SecureSession.init` 收窄 `public → internal`（tasks.md #8 / 设计⑥c）

**Files:**
- Modify: `packages/RelayProtocol/Sources/RelayProtocol/SecureSession.swift:19`（`public init` → `init`）
- Modify: `ios/CodexRemoteTests/RelayTransportTests.swift:4`（加 `@testable import RelayProtocol`）

**Interfaces:**
- Consumes: `SecureSession.init(role:keys:sessionId:keyEpoch:)`（收窄后仅 RelayProtocol 包内 + `@testable` 测试可见）
- Produces: 无生产 API 变化（构造点 `Handshake.swift:267/291` 均包内，照常）

> 事实核对：`SecureSession(` 构造点——生产 `Handshake.swift:267`（dev）、`:291`（iPad）**均包内**；测试 `SecureSessionTests.swift:13/14`（包内，**已有** `@testable import RelayProtocol`，无需改）+ 跨包 iOS `RelayTransportTests.swift:26/27`（当前是 `import RelayProtocol`，**需**改 `@testable`）。收窄后杜绝「包外越过握手直接构造会话」。

- [ ] **Step 1: 收窄 init**

`SecureSession.swift`：
```swift
// old:
    public init(role: RelayPeer, keys: KeySchedule.DirectionalKeys, sessionId: String, keyEpoch: UInt32) {
// new:
    init(role: RelayPeer, keys: KeySchedule.DirectionalKeys, sessionId: String, keyEpoch: UInt32) {
```

- [ ] **Step 2: RelayProtocol 包内验证（生产 + 包内测试仍编译）**

Run: `cd packages/RelayProtocol && swift test`。Expected：全测 PASS（`Handshake.swift` 包内构造 + `SecureSessionTests` 已 `@testable`）。

- [ ] **Step 3: iOS 测试改 `@testable import`**

`ios/CodexRemoteTests/RelayTransportTests.swift` 顶部：
```swift
// old:
import RelayProtocol
// new:
@testable import RelayProtocol
```
> 其它 iOS 测试文件（`RelayHandshakeTests` 等）构造的是 `RelayTransport(...)` 而非 `SecureSession(...)`，不受收窄影响，无需改。仅 `RelayTransportTests.swift`（`:26/27` 直接 `SecureSession(...)`）需 `@testable`。

- [ ] **Step 4: iOS 全测验证跨包 `@testable` 可编译**

Run（iOS 测试命令）。Expected：iOS 全测 PASS。
> **回退预案**：若 Xcode 环境下跨包 `@testable import RelayProtocol` 因 testability 未启用而编译失败（`module was not compiled for testing`），则改用包内测试工厂兜底：在 RelayProtocol 包内新增 `#if DEBUG`/测试可见的 `SecureSession.makeForTesting(role:keys:sessionId:keyEpoch:)` 工厂供跨包测试调用（保持 init internal）。**优先 `@testable`**，仅编译确失败才用工厂。

- [ ] **Step 5: Commit**

```bash
git add packages/RelayProtocol/Sources/RelayProtocol/SecureSession.swift \
        ios/CodexRemoteTests/RelayTransportTests.swift
git commit -m "refactor(relay): narrow SecureSession.init to internal; @testable in iOS tests"
```
勾选 tasks.md 第 8 项。

> **A/B/C 收口检查点**：此处四端应全绿——运行全部四端测试确认低风险机械项基线稳固，再进入 D 组。

archived-with: 2026-08-03-relay-t5-tail-cleanup
---

## D. spec 级行为升级（安全 + 能耗，tasks.md #9-#14）

### ⑥a 加密帧类型标签 + AAD 认证整个 header

> delta spec Requirement：*加密帧类型标签与未知帧类型 fail-closed*。三个 Scenario：已知类型正常分发 / 未知类型 fail-closed 拒绝 / 标签不削弱加密不变量。
>
> **两层 fail-closed**：*decode 层* 未定义 `kind` raw → `SecureEnvelope(decoding:)` 解码抛错拒帧（Swift 枚举 `RawRepresentable` Codable 对未知 raw 天然抛 `DecodingError`）；*AEAD 层* 篡改 `kind`/`v`/`keyEpoch`/`sessionId` → 接收端以被篡改值重建 AAD → tag 失配 → `AES.GCM.open` 抛 → `decryptFailed`。
>
> **kind 具体 case（从现有 SecureEnvelope 消费点枚举得出）**：过 `SecureSession` 的密文帧仅两类——①应用数据（JSON-RPC，iPad `send`/dev proxy stdout ↔ 对端）②安全控制信令（`SecureReady`，dev 握手后加密回传 stableSessionId，iPad 在启 read loop 前消费）。故 `RelayFrameKind { case appData = 0; case secureReady = 1 }`。

### Task 9: `SecureEnvelope` 增 `RelayFrameKind` + `kind` 字段 + AAD 规范编码（tasks.md #9 / 设计⑥a）

**Files:**
- Modify: `packages/RelayProtocol/Sources/RelayProtocol/SecureEnvelope.swift`
- Modify: `packages/RelayProtocol/Sources/RelayProtocol/SecureSession.swift`（`seal`/`open`）

**Interfaces:**
- Produces:
  - `public enum RelayFrameKind: UInt8, Codable, Sendable, Equatable { case appData = 0; case secureReady = 1 }`
  - `SecureEnvelope.kind: RelayFrameKind`（明文 header，与 `sender`/`counter` 同层）
  - `SecureEnvelope.init(v:sessionId:keyEpoch:sender:counter:kind:ciphertext:tag:)`
  - `static SecureEnvelope.headerAAD(v:keyEpoch:sessionId:sender:counter:kind:) -> Data`（收发共用**单一** AAD 规范编码源）
  - `SecureEnvelope.aad() -> Data`（转调 `headerAAD`）
  - `SecureSession.seal(_ plaintext: Data, kind: RelayFrameKind) throws -> SecureEnvelope`（签名变更：加 `kind`）
  - `SecureSession.open(_ env:) throws -> Data`（内部用 `env.aad()` 校验；签名不变，dispatch 由调用方读 `env.kind`）

- [ ] **Step 1: 写失败测试——AAD 往返 + 篡改 header 各字段 fail-closed**

在 `SecureSessionTests.swift` 追加（`pairedSessions()` harness 已存在）：

```swift
@Test func sealOpenRoundTripCarriesKind() throws {
    let (ipad, dev) = try pairedSessions()
    let env = try ipad.seal(Data("hi".utf8), kind: .appData)
    #expect(env.kind == .appData)
    #expect(try dev.open(env) == Data("hi".utf8))
}

@Test func tamperedKindFailsAEAD() throws {
    let (ipad, dev) = try pairedSessions()
    var env = try ipad.seal(Data("x".utf8), kind: .appData)
    env.kind = .secureReady                       // 中间人改 kind → AAD 失配
    #expect(throws: SecureSessionError.decryptFailed) { _ = try dev.open(env) }
}

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
```

- [ ] **Step 2: 运行确认失败（编译失败：`seal` 无 kind 参数 / `kind` 字段不存在）**

Run: `cd packages/RelayProtocol && swift test --filter sealOpenRoundTripCarriesKind`。Expected：编译失败或 FAIL（尚未实现）。

- [ ] **Step 3: 实现 `RelayFrameKind` + `kind` 字段 + AAD 规范编码**

`SecureEnvelope.swift`：
```swift
import Foundation

/// 谁发的这一帧（决定 nonce 方向绑定 + 路由 role）。
public enum RelayPeer: String, Codable, Sendable, Equatable {
    case iPad
    case devMachine
}

/// 加密帧类型标签（明文 header，与 sender/counter 同层）。接收端以此驱动分发，替代按 JSON 形状隐式推断。
/// 未定义 raw value 解码即抛错（decode 层 fail-closed）；标签进 AAD（AEAD 层 fail-closed）。
/// 不复用 `v`（v 是加密版本，语义不同不过载）。
public enum RelayFrameKind: UInt8, Codable, Sendable, Equatable {
    case appData = 0        // 应用数据（JSON-RPC 明文帧）
    case secureReady = 1    // 安全控制信令（dev 握手后加密回传 stableSessionId 的 SecureReady）
}

/// 加密帧信封。header 明文（路由/防重放/类型），ciphertext+tag 是 AES-GCM 密文体。
/// 明文 header 整体经 AES-GCM AAD 认证（篡改任一字段 → open fail-closed）。
/// base64 编码二进制字段，整体 JSON，一条 = 一个 ws text frame。
public struct SecureEnvelope: Codable, Sendable, Equatable {
    public var v: UInt8
    public var sessionId: String
    public var keyEpoch: UInt32
    public var sender: RelayPeer
    public var counter: UInt64
    public var kind: RelayFrameKind
    public var ciphertext: Data
    public var tag: Data

    public init(v: UInt8, sessionId: String, keyEpoch: UInt32,
                sender: RelayPeer, counter: UInt64, kind: RelayFrameKind,
                ciphertext: Data, tag: Data) {
        self.v = v; self.sessionId = sessionId; self.keyEpoch = keyEpoch
        self.sender = sender; self.counter = counter; self.kind = kind
        self.ciphertext = ciphertext; self.tag = tag
    }

    public func encoded() throws -> Data { try JSONEncoder().encode(self) }
    public init(decoding data: Data) throws {
        self = try JSONDecoder().decode(SecureEnvelope.self, from: data)
    }

    /// 明文 header 的确定性规范编码，用作 AES-GCM AAD。**收发共用唯一实现源**——
    /// 固定字段序、固定大端序、sessionId 长度前缀防歧义。任一字段被篡改 → AAD 失配 → open 抛错。
    public static func headerAAD(v: UInt8, keyEpoch: UInt32, sessionId: String,
                                 sender: RelayPeer, counter: UInt64, kind: RelayFrameKind) -> Data {
        var d = Data()
        d.append(v)                                                            // UInt8
        withUnsafeBytes(of: keyEpoch.bigEndian) { d.append(contentsOf: $0) }   // UInt32 BE
        let sid = Data(sessionId.utf8)
        withUnsafeBytes(of: UInt32(sid.count).bigEndian) { d.append(contentsOf: $0) } // 长度前缀
        d.append(sid)
        d.append(sender == .iPad ? 1 : 2)                                      // sender 标志
        withUnsafeBytes(of: counter.bigEndian) { d.append(contentsOf: $0) }    // UInt64 BE
        d.append(kind.rawValue)                                                // UInt8
        return d
    }

    /// 本信封 header 的 AAD（转调 headerAAD，单一实现源）。
    public func aad() -> Data {
        Self.headerAAD(v: v, keyEpoch: keyEpoch, sessionId: sessionId,
                       sender: sender, counter: counter, kind: kind)
    }
}
```

`SecureSession.swift`（`seal`/`open` 传 AAD）：
```swift
    public func seal(_ plaintext: Data, kind: RelayFrameKind) throws -> SecureEnvelope {
        lock.lock(); defer { lock.unlock() }
        outboundCounter += 1
        let counter = outboundCounter
        let key = keys.sendKey(as: role)
        let nonce = Self.nonce(sender: role, counter: counter)
        let aad = SecureEnvelope.headerAAD(v: RelayProtocolVersion.wire, keyEpoch: keyEpoch,
                                           sessionId: sessionId, sender: role, counter: counter, kind: kind)
        let box = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
        return SecureEnvelope(v: RelayProtocolVersion.wire, sessionId: sessionId, keyEpoch: keyEpoch,
                              sender: role, counter: counter, kind: kind,
                              ciphertext: box.ciphertext, tag: box.tag)
    }

    public func open(_ env: SecureEnvelope) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard env.sender != role else { throw SecureSessionError.wrongSender }
        guard env.counter > lastInbound else { throw SecureSessionError.replayOrOutOfOrder }
        let key = keys.sendKey(as: env.sender)
        let nonce = Self.nonce(sender: env.sender, counter: env.counter)
        do {
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: env.ciphertext, tag: env.tag)
            let pt = try AES.GCM.open(box, using: key, authenticating: env.aad())
            lastInbound = env.counter
            return pt
        } catch { throw SecureSessionError.decryptFailed }
    }
```

- [ ] **Step 4: 修复包内既有 `seal` 调用点编译**

`SecureSessionTests.swift` 中既有测试的 `seal(Data(...))` 调用需补 `kind:`（如 `seal(Data("hello".utf8), kind: .appData)`）。用 grep 找齐：
```bash
git grep -n "\.seal(" -- 'packages/RelayProtocol/**/*.swift'
```
逐个补 `kind: .appData`（既有 round-trip/replay/方向绑定测试均属 appData 语义）。

- [ ] **Step 5: 运行 RelayProtocol 全测**

Run: `cd packages/RelayProtocol && swift test`。Expected：全测 PASS（新增 3 个 + 既有全绿）。

- [ ] **Step 6: Commit**

```bash
git add packages/RelayProtocol/Sources/RelayProtocol/SecureEnvelope.swift \
        packages/RelayProtocol/Sources/RelayProtocol/SecureSession.swift \
        packages/RelayProtocol/Tests/RelayProtocolTests/SecureSessionTests.swift
git commit -m "feat(relay): add RelayFrameKind tag + AES-GCM AAD over full header"
```
勾选 tasks.md 第 9 项。

### Task 10: 未知/非法帧类型 decode-层 fail-closed（tasks.md #10 / 设计⑥a）

**Files:**
- Test: `packages/RelayProtocol/Tests/RelayProtocolTests/SecureSessionTests.swift`（或 `SecureEnvelopeTests.swift`）

**Interfaces:**
- Consumes: `SecureEnvelope(decoding:)`；`RelayFrameKind`（`UInt8` raw）
- Produces: 无（验证 Task 9 已实现的 decode-层 fail-closed；不新增生产代码，除非发现缺口）

> 决策：`kind` 为 `RelayFrameKind`（`RawRepresentable` `Codable`），JSON 中出现未定义 raw value（如 `99`）时 `JSONDecoder` 天然抛 `DecodingError` → `SecureEnvelope(decoding:)` 抛出 → 帧被拒。本 task 用测试固化此不变量；同时验证既有方向绑定/重放防护对每种 kind 照常。

- [ ] **Step 1: 写失败测试——未知 raw value 解码被拒 + 每种 kind 加密不变量**

```swift
@Test func unknownFrameKindRawValueRejectedAtDecode() throws {
    // 手工构造带未定义 kind raw(99) 的 SecureEnvelope JSON，解码应抛错（decode 层 fail-closed）。
    let json = """
    {"v":1,"sessionId":"s","keyEpoch":0,"sender":"iPad","counter":1,"kind":99,\
    "ciphertext":"AAAA","tag":"AAAAAAAAAAAAAAAAAAAAAA=="}
    """
    #expect(throws: (any Error).self) {
        _ = try SecureEnvelope(decoding: Data(json.utf8))
    }
}

@Test func directionBindingAndReplayHoldForSecureReadyKind() throws {
    // 方向绑定/重放防护对 .secureReady 与 .appData 一致生效（不因 kind 而弱化）。
    let (ipad, dev) = try pairedSessions()
    let env = try dev.seal(Data("ready".utf8), kind: .secureReady)   // dev 发
    #expect(env.kind == .secureReady)
    #expect(try ipad.open(env) == Data("ready".utf8))                // iPad 收，方向正确
    #expect(throws: SecureSessionError.wrongSender) { _ = try dev.open(env) } // 同侧不能开自己发的
    #expect(throws: SecureSessionError.replayOrOutOfOrder) { _ = try ipad.open(env) } // 重放拒
}
```

- [ ] **Step 2: 运行**

Run: `cd packages/RelayProtocol && swift test --filter unknownFrameKindRawValueRejectedAtDecode --filter directionBindingAndReplayHoldForSecureReadyKind`。
Expected：PASS（Task 9 的枚举 `Codable` 已给 decode-层拒绝；方向/重放逻辑未因 kind 改变）。若 `unknownFrameKindRawValueRejectedAtDecode` 未抛错 → **停止**，说明 `kind` 未按枚举严格解码，需在 `SecureEnvelope(decoding:)` 后补显式校验（decode-层 fail-closed 是硬需求）。

- [ ] **Step 3: Commit**

```bash
git add packages/RelayProtocol/Tests/RelayProtocolTests/SecureSessionTests.swift
git commit -m "test(relay): unknown frame kind rejected at decode; invariants hold per kind"
```
勾选 tasks.md 第 10 项。

### Task 11: 四端对齐新帧格式（iOS/dialout `seal` 传 kind + 按 kind 分发；server 透传不受影响）（tasks.md #11 / 设计⑥a）

**Files:**
- Modify: `ios/CodexRemote/Transport/RelayTransport.swift`（`send` 的 `seal`；read loop 按 `env.kind` 分发；握手期 SecureReady 消费点校验 kind）
- Modify: `relay-dialout/Sources/RelayDialoutCore/DialoutContext.swift:185`（SecureReady `seal` 传 `.secureReady`）
- Modify: `relay-dialout/Sources/relay-dialout/main.swift`（`:224` proxy stdout `seal` 传 `.appData`；`:167-171` 收帧按 `env.kind` 分发）
- Test: `ios/CodexRemoteTests/RelayTransportTests.swift`（已知类型正常分发；send 出的信封 kind 正确）

**Interfaces:**
- Consumes: `SecureSession.seal(_:kind:)`、`SecureEnvelope.kind`（Task 9）
- Produces: 无新增对外 API

> 说明：relay-server（`RelayRooms`）**零知识透传不解析 frame**，帧格式变更对它透明——server 侧无代码改动（仅在 Task 14 后跑全测确认透传不受影响）。

- [ ] **Step 1: 写/更新失败测试——send 出的信封 kind == .appData 且往返正确**

`RelayTransportTests.swift`（已在 Task 8 加 `@testable import RelayProtocol`）。现有 `testSendEmitsCiphertextEnvelopeNotPlaintext` 解析出 `SecureEnvelope` 后补断言：

```swift
        // send 出的应用数据帧应标记 .appData。
        let env = try SecureEnvelope(decoding: Data(frames[0].utf8))
        XCTAssertEqual(env.kind, .appData)
```
incoming 方向测试：dev 侧 `seal(..., kind: .appData)` 注入 mock ws → `incoming()` 吐明文（现有测试补 `kind:` 参数即可）。

- [ ] **Step 2: 运行确认失败（编译失败：`seal` 缺 kind）**

Run（iOS 测试命令，可 `-only-testing:CodexRemoteTests/RelayTransportTests`）。Expected：编译失败（`seal` 签名变更未适配）。

- [ ] **Step 3: iOS 实现——`send` 传 kind + read loop 按 kind 分发**

`RelayTransport.swift` `send`（约 `:497`）：
```swift
        let env = try session.seal(Data(text.utf8), kind: .appData)
```
read loop（约 `:229-231`）按 `env.kind` 分发，替代无差别 emit：
```swift
                let env = try SecureEnvelope(decoding: Data(frame.utf8))
                let plaintext = try session.open(env)
                switch env.kind {
                case .appData:
                    emit(String(decoding: plaintext, as: UTF8.self))
                case .secureReady:
                    // 业务 read loop 不期望再收 SecureReady（握手期已消费）；fail-closed 忽略，不误当应用数据 emit。
                    rtLog.error("read loop 收到意外 SecureReady 帧，忽略")
                }
```
握手期 SecureReady 消费点（约 `:481-483`）补 kind 校验（fail-closed）：
```swift
        let readyEnv = try SecureEnvelope(decoding: Data(readyText.utf8))
        guard readyEnv.kind == .secureReady else {
            throw TransportError.channelClosed(reason: "握手期期望 SecureReady 帧，实际 kind=\(readyEnv.kind)")
        }
        let readyPlain = try secure.open(readyEnv)
```

- [ ] **Step 4: dialout 实现——SecureReady 与 proxy 输出各自标 kind + 收帧按 kind 分发**

`DialoutContext.swift:185`：
```swift
        let env = try session.seal(JSONEncoder().encode(ready), kind: .secureReady)
```
`main.swift:224`（pump bridge outbound，proxy stdout → 密文）：
```swift
                      let env = try? session.seal(Data(line.utf8), kind: .appData),
```
`main.swift:167-171`（`handlePayload` 收 SecureEnvelope 后按 kind 分发；dev 侧只应收 iPad 发来的 `.appData`）：
```swift
        if let session = context.session, let env = try? SecureEnvelope(decoding: data) {
            guard env.kind == .appData else { return }   // dev 侧只期望应用数据；非期望 kind fail-closed 丢弃
            guard let plaintext = try? session.open(env) else { return }
            ensureBridgeStarted()
            if let s = String(data: plaintext, encoding: .utf8) {
                bridge.write(s)
            }
            return
        }
```

- [ ] **Step 5: 运行 iOS + dialout 测试**

Run: `cd relay-dialout && swift test`（Expected：PASS）；再跑 iOS 测试命令（Expected：PASS）。

- [ ] **Step 6: Commit**

```bash
git add ios/CodexRemote/Transport/RelayTransport.swift \
        ios/CodexRemoteTests/RelayTransportTests.swift \
        relay-dialout/Sources/RelayDialoutCore/DialoutContext.swift \
        relay-dialout/Sources/relay-dialout/main.swift
git commit -m "feat(relay): dispatch frames by RelayFrameKind across iOS + dialout"
```
勾选 tasks.md 第 11 项。

### ⑥d relay 对端未连接时的有界缓冲

> delta spec Requirement：*relay 对端未连接时的有界缓冲与按序投递*。三个 Scenario：对端未连接时有界缓冲并加入后按序投递 / 达上限不无界增长（显式策略） / 不破坏零知识且随房间回收释放。
>
> **决策**：`Room` 为「当前缺席对端」方向维护有界 FIFO（不透明 `String` 密文帧）；`forward` 对端槽空 → 入队；`join` 成功后按 FIFO 原序 flush，再恢复实时。硬上限：每房间每方向 **帧数 ≤ 64 且 总字节 ≤ 512 KiB**；超限 **reject-newest**（O(1) 直接拒新，保前缀因果序）。worst-case ≈ `maxRooms`(500) × 512 KiB ≈ 256 MiB 有界。缓冲随 `Room` 回收释放。
>
> **flush 锁序（正确性）**：`join` 持锁**快照并摘走**该方向缓冲（置空），**锁外**逐帧投递——避免 (a) flush 期新 live 帧插到缓冲帧之前破坏顺序、(b) 持锁调 sink 造成重入/长临界区。

### Task 12: `RelayRoom` 每房间有界 FIFO 缓冲 + join 按序 flush（tasks.md #12 / 设计⑥d）

**Files:**
- Modify: `relay-server/Sources/RelayServerCore/RelayRoom.swift`

**Interfaces:**
- Consumes: `RelayLimits.maxRoomBufferedFrames` / `.maxRoomBufferedBytes`（Task 13 定义；本 task 先引用常量名，Task 13 落地定义——**两 task 相邻，若单 task 执行则本 task 内先加常量**）
- Produces: `RelayRooms.forward`（对端缺席时缓冲而非丢弃）；`RelayRooms.join`（成功后按序 flush 缓冲）；`Room` 结构增 `pendingForIpad`/`pendingForDev` FIFO + 字节计数

> 依赖说明：Task 12 用到 Task 13 的常量。为让每 task 独立可测，**在 Task 12 内先补上常量定义**（Task 13 再补测试与边界断言）；或按 subagent 执行时把 12+13 合为一个 commit。下方 Step 已含常量。

- [ ] **Step 1: 写失败测试——对端未连接缓冲、加入后按序全投**

`RelayRoomTests.swift` 追加：
```swift
// ⑥d：对端未加入时 forward 的帧被缓冲，对端 join 后按原序全部投递。
@Test func framesBufferedUntilPeerJoinsThenDeliveredInOrder() {
    let rooms = RelayRooms()
    var devRx: [String] = []
    // iPad 先 join 并连发 3 帧；dev 尚未加入 → 缓冲。
    rooms.join(sessionId: "s", role: .iPad) { _ in }
    rooms.forward(sessionId: "s", from: .iPad, frame: "a")
    rooms.forward(sessionId: "s", from: .iPad, frame: "b")
    rooms.forward(sessionId: "s", from: .iPad, frame: "c")
    #expect(devRx.isEmpty)                       // 对端未加入 → 尚未投递
    rooms.join(sessionId: "s", role: .devMachine) { devRx.append($0) }
    #expect(devRx == ["a", "b", "c"])            // dev 加入后按原序全投
    // 其后实时转发衔接在 flush 之后。
    rooms.forward(sessionId: "s", from: .iPad, frame: "d")
    #expect(devRx == ["a", "b", "c", "d"])
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd relay-server && swift test --filter framesBufferedUntilPeerJoinsThenDeliveredInOrder`。Expected：FAIL（当前 `forward` 对端缺席直接丢弃，`devRx` 空）。

- [ ] **Step 3: 实现——`Room` 加缓冲 + `forward` 缓冲 + `join` flush**

`RelayRoom.swift`：`Room` 结构增缓冲字段（缺席对端方向）：
```swift
    private struct Room {
        var ipad: Slot?
        var dev: Slot?
        // 缺席对端方向的有界 FIFO（不透明密文帧）+ 字节计数。零知识：只存不解析。
        var pendingForIpad: [String] = []   // dev 发、iPad 缺席时缓冲
        var pendingForDev: [String] = []    // iPad 发、dev 缺席时缓冲
        var pendingForIpadBytes = 0
        var pendingForDevBytes = 0
    }
```
`forward`（对端缺席入队，reject-newest）：
```swift
    /// 把 frame 投给**对端** sink；对端缺席时入有界 FIFO 缓冲（对端 join 后按序 flush）。
    /// 达帧数或字节上限 → reject-newest（O(1) 拒新，保前缀因果序）。零知识：不解析 frame。
    public func forward(sessionId: String, from: RelayPeer, frame: String) {
        lock.lock()
        guard var room = rooms[sessionId] else { lock.unlock(); return }
        let target: Sink?
        switch from {
        case .iPad:       target = room.dev?.sink
        case .devMachine: target = room.ipad?.sink
        }
        if let target {
            lock.unlock()
            target(frame)        // 对端在场 → 锁外实时投递
            return
        }
        // 对端缺席 → 有界缓冲（reject-newest）。
        let bytes = frame.utf8.count
        switch from {
        case .iPad:   // 投给 dev，dev 缺席 → 存 pendingForDev
            if room.pendingForDev.count < RelayLimits.maxRoomBufferedFrames &&
               room.pendingForDevBytes + bytes <= RelayLimits.maxRoomBufferedBytes {
                room.pendingForDev.append(frame)
                room.pendingForDevBytes += bytes
            }   // else: 达上限，丢弃新帧（reject-newest）
        case .devMachine:   // 投给 iPad，iPad 缺席 → 存 pendingForIpad
            if room.pendingForIpad.count < RelayLimits.maxRoomBufferedFrames &&
               room.pendingForIpadBytes + bytes <= RelayLimits.maxRoomBufferedBytes {
                room.pendingForIpad.append(frame)
                room.pendingForIpadBytes += bytes
            }
        }
        rooms[sessionId] = room
        lock.unlock()
    }
```
`join`（持锁摘走缓冲、锁外 flush；**去掉 defer unlock**，改显式 unlock 以便锁外投递）：
```swift
    @discardableResult
    public func join(sessionId: String, role: RelayPeer, sink: @escaping Sink) -> JoinResult {
        lock.lock()
        var room = rooms[sessionId] ?? Room()
        let connId = UUID()
        var flush: [String] = []
        switch role {
        case .iPad:
            if room.ipad != nil { lock.unlock(); return .rejectedRoleOccupied }
            room.ipad = Slot(connId: connId, sink: sink)
            flush = room.pendingForIpad                 // 摘走本方向缓冲
            room.pendingForIpad = []; room.pendingForIpadBytes = 0
        case .devMachine:
            if room.dev != nil { lock.unlock(); return .rejectedRoleOccupied }
            room.dev = Slot(connId: connId, sink: sink)
            flush = room.pendingForDev
            room.pendingForDev = []; room.pendingForDevBytes = 0
        }
        rooms[sessionId] = room
        lock.unlock()
        for f in flush { sink(f) }                      // 锁外按序投递（避免持锁调 sink 重入/长临界区）
        return .joined(connId)
    }
```
> `leave` 不变——`Room` 从 `rooms` 移除时缓冲随之释放（Task 14 验证）。

- [ ] **Step 4: 在 `RelayLimits` 补常量**（若 Task 13 尚未落地）

见 Task 13 Step 1 的常量定义；单 task 执行时先加，避免编译失败。

- [ ] **Step 5: 运行**

Run: `cd relay-server && swift test --filter framesBufferedUntilPeerJoinsThenDeliveredInOrder`。Expected：PASS。再跑 `cd relay-server && swift test` 确认既有 RelayRoomTests（转发/拒后到/精确 leave）全绿。

- [ ] **Step 6: Commit**

```bash
git add relay-server/Sources/RelayServerCore/RelayRoom.swift \
        relay-server/Sources/RelayServerCore/FrameAccumulator.swift
git commit -m "feat(relay-server): bounded FIFO buffer per room with in-order flush on join"
```
勾选 tasks.md 第 12 项。

### Task 13: 缓冲上限常量 + 房间资源边界（tasks.md #13 / 设计⑥d）

**Files:**
- Modify: `relay-server/Sources/RelayServerCore/FrameAccumulator.swift`（`RelayLimits` enum）

**Interfaces:**
- Produces: `RelayLimits.maxRoomBufferedFrames: Int = 64`、`RelayLimits.maxRoomBufferedBytes: Int = 512 * 1024`

> 常量置于 `RelayLimits` 内，与 `maxMessageBytes`/`maxRooms` 同处（设计要求）。

- [ ] **Step 1: 定义常量**

在 `RelayLimits` enum（`FrameAccumulator.swift`）内追加：
```swift
    /// ⑥d：每房间每方向「对端缺席待投递」缓冲的帧数上限。达上限 reject-newest。
    public static let maxRoomBufferedFrames = 64
    /// ⑥d：每房间每方向待投递缓冲的总字节上限（512 KiB）。达上限 reject-newest。
    /// worst-case 内存 = maxRooms(500) × 512 KiB ≈ 256 MiB，有界。
    public static let maxRoomBufferedBytes = 512 * 1024
```

- [ ] **Step 2: 编译 + 全测**

Run: `cd relay-server && swift test`。Expected：全测 PASS（常量被 Task 12 的 `forward`/`join` 引用）。

- [ ] **Step 3: Commit**（若与 Task 12 合并执行则并入其 commit）

```bash
git add relay-server/Sources/RelayServerCore/FrameAccumulator.swift
git commit -m "feat(relay-server): add per-room buffer caps to RelayLimits"
```
勾选 tasks.md 第 13 项。

### Task 14: relay 缓冲测试——上限/回收/零知识（tasks.md #14 / 设计⑥d）

**Files:**
- Test: `relay-server/Tests/RelayServerCoreTests/RelayRoomTests.swift`

**Interfaces:**
- Consumes: `RelayRooms.forward`/`join`/`leave`；`RelayLimits.maxRoomBufferedFrames`/`.maxRoomBufferedBytes`
- Produces: 无

- [ ] **Step 1: 写测试——帧数上限 reject-newest（保前缀）**

```swift
// ⑥d：待投递缓冲达帧数上限 → reject-newest（丢新、保已缓冲前缀因果序），不无界增长。
@Test func bufferRejectsNewestBeyondFrameCap() {
    let rooms = RelayRooms()
    rooms.join(sessionId: "s", role: .iPad) { _ in }
    let cap = RelayLimits.maxRoomBufferedFrames
    for i in 0..<(cap + 10) {                        // 超上限 10 帧
        rooms.forward(sessionId: "s", from: .iPad, frame: "f\(i)")
    }
    var devRx: [String] = []
    rooms.join(sessionId: "s", role: .devMachine) { devRx.append($0) }
    #expect(devRx.count == cap)                      // 只缓冲上限内的帧
    #expect(devRx.first == "f0")                     // 保前缀：最旧保留
    #expect(devRx.last == "f\(cap - 1)")             // reject-newest：超出的被丢
}
```

- [ ] **Step 2: 写测试——字节上限**

```swift
// ⑥d：字节上限先于帧数触发时也 reject-newest。
@Test func bufferRejectsBeyondByteCap() {
    let rooms = RelayRooms()
    rooms.join(sessionId: "s", role: .iPad) { _ in }
    let big = String(repeating: "x", count: 200 * 1024)   // 200 KiB/帧
    for _ in 0..<10 { rooms.forward(sessionId: "s", from: .iPad, frame: big) }  // 10×200KiB=2MiB > 512KiB
    var devRx: [String] = []
    rooms.join(sessionId: "s", role: .devMachine) { devRx.append($0) }
    // 512 KiB / 200 KiB → 至多 2 帧（第 3 帧起 200KiB 累加超 512KiB 被拒）。
    #expect(devRx.count == 2)
    #expect(devRx.allSatisfy { $0 == big })
}
```

- [ ] **Step 3: 写测试——房间回收释放缓冲（无泄漏 + 无陈旧 flush）**

```swift
// ⑥d：缓冲后两端均离开 → 房间回收，缓冲随之释放；新 join 不再收到陈旧帧。
@Test func bufferReleasedOnRoomRecycle() {
    let rooms = RelayRooms()
    guard case let .joined(ipadId) = rooms.join(sessionId: "s", role: .iPad, sink: { _ in }) else {
        return #expect(Bool(false))
    }
    rooms.forward(sessionId: "s", from: .iPad, frame: "stale")   // 缓冲给缺席的 dev
    rooms.leave(sessionId: "s", role: .iPad, connId: ipadId)     // 两端皆空 → 房间回收
    // 全新使用同一 sessionId：dev 先 join 不应收到上一轮的 "stale"（缓冲已随房间释放）。
    var devRx: [String] = []
    rooms.join(sessionId: "s", role: .devMachine) { devRx.append($0) }
    #expect(devRx.isEmpty)
}
```

- [ ] **Step 4: 写测试——零知识（不透明帧原样透传，不解析）**

```swift
// ⑥d：缓冲/投递全程只持有不透明字符串，不解析内容（非 JSON 帧原样透传）。
@Test func bufferKeepsFramesOpaque() {
    let rooms = RelayRooms()
    rooms.join(sessionId: "s", role: .iPad) { _ in }
    let opaque = "not-a-json-\u{0000}-binary-ish-\u{FFFD}"
    rooms.forward(sessionId: "s", from: .iPad, frame: opaque)
    var devRx: [String] = []
    rooms.join(sessionId: "s", role: .devMachine) { devRx.append($0) }
    #expect(devRx == [opaque])   // 原样投递，未被解析/改写
}
```

- [ ] **Step 5: 运行 relay-server 全测**

Run: `cd relay-server && swift test`。Expected：全测 PASS（新增 4 个 + 既有全绿，含 `LocalE2EIntegrationTests` 三端撮合、`RelayPipelineTests`）。

- [ ] **Step 6: Commit**

```bash
git add relay-server/Tests/RelayServerCoreTests/RelayRoomTests.swift
git commit -m "test(relay-server): buffer cap reject-newest, recycle release, zero-knowledge"
```
勾选 tasks.md 第 14 项。

archived-with: 2026-08-03-relay-t5-tail-cleanup
---

## E. 验证（tasks.md #15-#17）

### Task 15: 四端全量测试全绿（tasks.md #15）

- [ ] **Step 1: 依次跑四端全量测试**

```bash
cd packages/RelayProtocol && swift test
cd relay-dialout && swift test
cd relay-server && swift test
cd ios && xcodebuild test -scheme CodexRemote \
  -destination 'platform=iOS Simulator,name=iPad-Test' -derivedDataPath DerivedData
```
Expected：四端全部 PASS。任一失败 → 加载 `superpowers:systematic-debugging`，根因定位后再修，不跳过。

- [ ] **Step 2: 勾选 tasks.md 第 15 项**（不单独 commit，或与后续验证合并记录）

### Task 16: `openspec validate --strict`（tasks.md #16）

- [ ] **Step 1: 运行 strict 校验**

```bash
openspec validate relay-t5-tail-cleanup --strict
```
Expected：通过（delta spec 两个 ADDED Requirement 各含 ≥1 Scenario，格式合规）。若报错按提示修正 delta spec 格式（不改需求语义）。

- [ ] **Step 2: 勾选 tasks.md 第 16 项**

### Task 17: 安全回归（tasks.md #17）

逐条对照 delta spec 与设计安全分析，确认红线守住：

- [ ] **Step 1: ⑥a fail-closed + AEAD 不变量**
  - 已知 kind 正常分发（`sealOpenRoundTripCarriesKind`、`directionBindingAndReplayHoldForSecureReadyKind`）✓
  - 未知 kind decode 层拒绝（`unknownFrameKindRawValueRejectedAtDecode`）✓
  - 篡改 `kind`/`v`/`keyEpoch`/`sessionId` → `decryptFailed`（`tamperedKindFailsAEAD`、`tamperedHeaderFieldsFailAEAD`）✓
  - AAD 收发共用单一实现源（`SecureEnvelope.headerAAD`）——grep 确认无第二处 AAD 编码：
    ```bash
    git grep -n "authenticating:" -- 'packages/RelayProtocol/**/*.swift'   # 期望仅 seal/open 各一处，均传 headerAAD/aad()
    ```

- [ ] **Step 2: ⑥d 内存有界 + 零知识**
  - 帧数/字节上限 reject-newest（`bufferRejectsNewestBeyondFrameCap`、`bufferRejectsBeyondByteCap`）✓
  - 房间回收释放缓冲（`bufferReleasedOnRoomRecycle`）✓
  - 零知识不解析（`bufferKeepsFramesOpaque`）✓
  - grep 确认 `RelayRooms` 未新增 frame 解析：
    ```bash
    git grep -n "JSONDecoder\|SecureEnvelope\|decode" -- 'relay-server/Sources/RelayServerCore/RelayRoom.swift'  # 期望零命中
    ```

- [ ] **Step 3: ⑥b 进程铁律未违背（无宽匹配 kill）**
  ```bash
  git grep -n "pkill\|killall\|\"kill\"\|/usr/bin/kill" -- 'relay-dialout/Sources/**/*.swift'   # 期望零命中
  git grep -n "waitUntilExit" -- 'relay-dialout/Sources/RelayDialoutCore/ProxyBridge.swift'      # 期望命中 terminate() 内一处
  ```
  确认 `terminate()` 仅 `process.terminate()` + `process.waitUntilExit()`，只操作自身 `process` 句柄。

- [ ] **Step 4: 死代码保留铁律复核**
  ```bash
  git grep -n "identityPublicKeyRaw" -- 'relay-dialout/Sources/**/*.swift'   # 期望仍命中 DevKeyStore.swift:26（保留、未误删）
  ```

- [ ] **Step 5: 勾选 tasks.md 第 17 项，并做收尾 commit（若有 tasks.md 勾选变更）**

```bash
git add openspec/changes/relay-t5-tail-cleanup/tasks.md
git commit -m "chore(relay-t5): mark verification tasks complete"
```

> **worktree 收尾（若在 worktree 中）**：`openspec/`+`docs/` 是 gitignored worktree-local 副本。归档前须把 openspec 归档产物 rsync 回主库（见 memory `worktree-openspec-gitignore-loss`），否则删 worktree = 归档产物丢失。归档在主库执行。

archived-with: 2026-08-03-relay-t5-tail-cleanup
---

## Self-Review

**1. Spec 覆盖**（delta spec 两个 ADDED Requirement）：
- *加密帧类型标签与未知帧类型 fail-closed* → Task 9（字段 + AAD）、Task 10（decode 层拒绝 + 每种 kind 不变量）、Task 11（四端分发对齐）。三个 Scenario 全覆盖（已知分发 / 未知拒绝 / 不削弱加密）✓
- *relay 对端未连接时的有界缓冲与按序投递* → Task 12（缓冲 + flush）、Task 13（上限常量）、Task 14（上限/回收/零知识测试）。三个 Scenario 全覆盖（按序投递 / 上限不无界 / 零知识+回收释放）✓
- tasks.md #1-#17 → 计划 Task 1-17 一一映射；A/B/C/D/E 分组与「先机械后 spec 级」顺序一致 ✓

**2. Placeholder 扫描**：无 TBD/TODO 占位；每个代码步骤含实际代码；测试步骤含真实断言。`main.swift:214` 的 `/* TODO(集成) */` 明确标注为「保留的真 TODO，非 Task 13 陈旧措辞」，非计划占位 ✓

**3. 类型一致性**：
- `RelayFrameKind`（`.appData`/`.secureReady`）在 Task 9 定义，Task 10/11/日后引用一致 ✓
- `SecureSession.seal(_:kind:)` 签名在 Task 9 变更，Task 11 所有调用点（iOS send、dialout SecureReady、dialout proxy stdout）+ Task 9 Step 4（包内既有测试）全部适配 ✓
- `SecureEnvelope.headerAAD(...)` / `.aad()` 单一实现源，seal 用 static、open 用实例方法，收发一致 ✓
- `RelayLimits.maxRoomBufferedFrames`/`.maxRoomBufferedBytes` 在 Task 13 定义，Task 12 `forward`/`join` + Task 14 测试引用同名 ✓
- `RelayRooms.join` 去 `defer unlock` 改显式 unlock（锁外 flush）——`forward` 同步采用显式 unlock，锁序一致 ✓

计划完成，无未覆盖需求。
