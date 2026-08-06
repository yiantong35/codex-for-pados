# 验证报告：relay-t5-tail-cleanup

- 日期：2026-08-03
- 验证模式：full（17 tasks / 1 capability delta spec / 19 files；均超轻量阈值）
- base-ref：`97ed4238b08e91d17f927e8be5ce6672344833df`（origin/master）
- 提交范围：14 commits（`git log 97ed4238...HEAD`），工作树 clean

## Summary

| 维度 | 结论 |
|------|------|
| Completeness | 17/17 tasks `[x]`；2 ADDED Requirement 均已实现 |
| Correctness | 2/2 requirement 覆盖；6/6 scenario 有实现 + 通过测试 |
| Coherence | Design Doc 4 个 Open Question 全按定稿落地；delta spec ↔ design 无漂移 |

**最终评定：全部检查通过，无 CRITICAL / WARNING / SUGGESTION。可归档。**

## 四端新鲜复现（verify 上下文重跑，Iron Law 独立取证）

| 端 | 结果 |
|----|------|
| RelayProtocol | 34 tests / 0 failures ✓ |
| relay-dialout | 39 tests / 0 failures ✓ |
| relay-server | 29 tests / 0 failures ✓ |
| iOS CodexRemote | 462 tests / 0 failures，`** TEST SUCCEEDED **` ✓ |
| `openspec validate --strict` | `Change 'relay-t5-tail-cleanup' is valid` ✓ |

> 说明：build 阶段各 subagent 报告的分组计数（如 RelayProtocol 39 含跨包/其它 target）与 verify 上下文按包 target 重跑的计数口径不同；本表以 verify 现场 `swift test` / `xcodebuild` 单包 target 真实输出为准，全 0 失败。

## Completeness

- **Task 完成**：`grep -c '- [ ]' tasks.md` = 0，17 项全 `[x]`（A 组 1-4 / B 组 5-6 / C 组 7-8 / D 组 9-14 / E 组 15-17）。
- **Requirement 覆盖**：delta spec `specs/relay-e2e-transport/spec.md` 含 2 个 ADDED Requirement，均有实现锚点（见 Correctness）。

## Correctness — Requirement → 实现 → 测试映射

### R1 加密帧类型标签与未知帧类型 fail-closed

| 锚点 | 证据 |
|------|------|
| 帧类型标签 | `RelayProtocol/SecureEnvelope.swift:12` `enum RelayFrameKind: UInt8`（`appData=0`/`secureReady=1`）+ `:26` `public var kind` |
| AAD 单一实现源 | `SecureEnvelope.swift:45` `static headerAAD(...)`（认证整个明文 header：v‖keyEpoch‖sessionId‖sender‖counter‖kind）；`:60` `aad()` 转调 |
| seal/open 对称 | `SecureSession.swift:42` seal 用 `headerAAD(...)`；`:59` open 用 `env.aad()`，双向同源 |
| fail-closed 分发（两层） | 层1 decode 未定义 rawValue → 拒帧；层2 篡改 kind → 接收端以篡改值重建 AAD → `AES.GCM.open` 抛错。iOS `RelayTransport.swift:214` `switch env.kind` + `:471` `guard readyEnv.kind == .secureReady`；dialout `main.swift:170` `guard env.kind == .appData else { return }` |

- Scenario「已知帧类型正常分发」→ `SecureSessionTests.swift` 已知 kind 往返 + 携带正确 kind 断言。
- Scenario「未知帧类型被 fail-closed 拒绝」→ 未知 rawValue decode 拒帧测试（commit `9959491e`）。
- Scenario「帧类型标签不削弱加密不变量」→ 每种 kind 的方向绑定/计数单调重放回归（`tamperedTagRejected`/`tamperedCounterRejected`/`replayedFrameRejected`/`counterIncrementsMonotonically` 全绿）；relay-server 侧零知识（下同）。

### R2 relay 对端未连接时的有界缓冲与按序投递

| 锚点 | 证据 |
|------|------|
| 双封顶上限 | `relay-server/FrameAccumulator.swift:21` `maxRoomBufferedFrames=64` + `:24` `maxRoomBufferedBytes=512*1024` |
| reject-newest（O(1)、DoS 安全） | `RelayRoom.swift:87-96` 达帧数或字节上限即停止入队丢弃新帧，注释 `// else: 达上限，丢弃新帧` |
| 按序 flush | `RelayRoom.swift:40-63` lock-snapshot-then-drain：持锁快照本方向缓冲并清空，锁外 FIFO `for f in flush { sink(f) }`，避免持锁调 sink 与新 live 帧插队 |
| 房间回收释放 | `RelayRoom.swift:105-113` `leave` connId 精确匹配置 nil；两端皆空 → `rooms[sessionId] = nil` 一并释放缓冲 |
| 零知识不破坏 | relay-server 全源 `grep JSONDecoder/JSONSerialization/decode(` 无命中，只缓存不透明 String 密文帧 |

- Scenario「对端未连接时帧被有界缓冲并在加入后按序投递」→ `RelayRoomTests` join 后按原序全投递测试。
- Scenario「缓冲达到上限时不无界增长」→ flood 至上限 reject-newest 内存有界断言（`accumulatorOverflowsBeyondCap` + RelayRoom 上限测试）。
- Scenario「缓冲不破坏零知识且随房间回收释放」→ 只密文断言 + 房间回收释放缓冲测试（commit `b8ac3259`）。

## Coherence

### Design Doc 决策符合度（4 个 Open Question 定稿逐项核对）

| 决策 | 落地 |
|------|------|
| ⑥a AAD 认证**整个** header（非仅 kind） | ✓ `headerAAD` 含 v/keyEpoch/sessionId/sender/counter/kind 六字段，顺带把既有未认证的 v/keyEpoch/sessionId 升为显式 fail-closed |
| ⑥d reject-newest（非 drop-oldest） | ✓ `RelayRoom.swift:87-96` O(1) 拒新，保已缓冲前缀因果序 |
| ⑥c `@testable import`（非工厂） | ✓ `SecureSession.init` public→internal（commit `0c757305`），无新增生产/测试面 API |
| ⑤a `certificateVerification == .fullVerification` 断言 | ✓ `DialoutTLSTests.swift:15` |

### 安全铁律回归（security-first 原则）

- fail-closed 两层（未知/篡改一律拒，不回退已知路径）✓
- 删除保全律：dialout `DevKeyStore.identityPublicKeyRaw` 保留且 `main.swift:106` 在用；iOS `RelayE2EKeyManager.identityPublicKeyRaw()` 已删（全仓 grep 仅 dialout 保留）✓
- 进程铁律：`ProxyBridge.terminate()` 仅停自身 spawn PID（`:92-95` `process.terminate()`+`waitUntilExit()`），全端无 pkill/宽匹配 kill ✓
- ⑤b `LiveTransport.swift` relayTOFUKey 非空 assert（release 空操作，零运行时行为变更）✓
- 零知识：relay-server 只转发/缓存不透明密文，不解析 ✓

### 能耗铁律回归（energy-awareness 原则）

- ⑥d 被动缓冲：事件驱动 flush（join 触发），无轮询 timer/空转线程 ✓
- ⑥b 子进程回收：`waitUntilExit()` 一次性同步等待，非忙等 ✓

### delta spec ↔ design doc 漂移检测

无漂移。brainstorm-summary.md「Spec Patches」记为「暂无需改写 delta spec 结构；3+3 scenario 已覆盖 ⑥a 篡改 kind 触发 AEAD 失败 / ⑥d reject-newest 超限行为，无需新增」；实现与 delta spec 6 scenario 一一对应，Design Doc 存在于 `docs/superpowers/specs/2026-08-03-relay-t5-tail-cleanup-design.md`（可定位、与本 change 关联）。

## 结论

全部检查通过，无 CRITICAL / WARNING / SUGGESTION。change 可进入归档。
