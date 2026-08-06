---
comet_change: relay-t5-tail-cleanup
role: technical-design
canonical_spec: openspec
archived-with: 2026-08-03-relay-t5-tail-cleanup
status: final
---

# Design Doc — relay-t5-tail-cleanup

> 技术设计（HOW）。WHAT/验收归 OpenSpec delta spec（`openspec/changes/relay-t5-tail-cleanup/specs/relay-e2e-transport/spec.md`），本文不复述需求，只落实现方案、安全/能耗分析与测试策略。
>
> **代码事实基线：`origin/master @ 97ed4238`**（本地 `master @ ef2e9a0b` 是 doc-only 分叉、缺 SSH 移除合并，不可作代码依据）。build 阶段须从 `origin/master` 起 worktree。

## Context

T5（relay）主线全归档、SSH 已移除（`remove-ssh-transport` PR#46）。剩余是历次 review 留下的一批尾巴：死代码、陈旧注释、缺失测试断言、进程/可见性收紧，加两处「探路期」占位（加密帧类型、relay 缓冲）升级为正式实现。前 8 项低风险机械收敛；后 2 项（⑥a/⑥d）是 spec 级行为变更，需安全 + 能耗分析。**app 未上线 → 无线上兼容负担**，帧格式可干净版本化。

## 分组与单元边界

四端（SwiftPM 包/目标）：`RelayProtocol` 包 / `relay-dialout` / `relay-server` / iOS `CodexRemote`。各改动落在既有单元内，不新增跨端接口面。

archived-with: 2026-08-03-relay-t5-tail-cleanup
status: final
---

## A. 死代码 / 陈旧注释（①②③④）— 零行为

已用 `git grep origin/master` 核实调用方，四端全量测试兜底删除安全性：

| 项 | 位置（origin/master） | 事实 | 动作 |
|---|---|---|---|
| ① | `ios/CodexRemote/Transport/RelayTransport.swift` `init(ws:)` 单参占位 | `git grep "RelayTransport(ws"` **零命中**（仅定义）；生产走 `init(channelFactory:...)`，测试走 `init(session:ws:)` | 删该 init |
| ② | `ios/CodexRemote/Security/RelayE2EKeyManager.swift:59` `identityPublicKeyRaw()` | iOS 端**零调用方**；`relay-dialout` 的 `DevKeyStore.identityPublicKeyRaw`（`:26`）是**另一类型的 `var`**、活跃使用 → **保留不动** | 删 iOS 侧方法 |
| ③ | `RelayE2EKeyManager.swift:6` 注释「复用 KeyManager.swift 定义的 KeyStoring 协议」 | `KeyManager.swift` 已被 SSH 移除删除，现为 `ios/CodexRemote/Security/KeyStoring.swift` | 注释改指 `KeyStoring.swift` |
| ④ | `relay-dialout/Sources/relay-dialout/main.swift` 行 22/128/214 `TODO(Task 13)` | ws 拨出已落地（`DialoutWSHandler` + 转发测试全绿），「骨架/尚未接入」措辞过时 | 刷新为现状注释 |

**风险仅「误删活代码」**：已核实无调用方；删除后靠四端全量测试回归。

archived-with: 2026-08-03-relay-t5-tail-cleanup
status: final
---

## B. 测试硬化（⑤a / ⑤b）— 仅测试

### ⑤a DialoutTLS 完整证书校验断言（符号已定，非占位）

`DialoutTLS.makeClientHandler`（origin/master）：
```swift
let context = try NIOSSLContext(configuration: .makeClientConfiguration())
return try NIOSSLClientHandler(context: context, serverHostname: serverHostname)
```
- `TLSConfiguration.makeClientConfiguration()` 的 NIOSSL 默认 `certificateVerification == .fullVerification`。
- `NIOSSLClientHandler(context:serverHostname:)` 传入主机名 → 启用 SNI + 证书主机名校验（注释已声明「须主机名非 IP」）。

**断言（`DialoutTLSTests`）**：`TLSConfiguration.makeClientConfiguration().certificateVerification == .fullVerification`，锁死不变量、防未来回归成 `.none` / `.noHostnameVerification`。若 build 阶段发现构造方式已调整，以实际构造点为准再断言（防断言写错反成假绿）。

### ⑤b LiveTransport TOFU 兜底不变量

`ios/CodexRemote/App/LiveTransport.swift` 中 `tofuMachineKey: config.relayTOFUKey ?? relayURL` 等兜底分支在正常路径不可达。补前置断言/`assert` 固化「正常路径 `relayTOFUKey` 恒非空」不变量，防未来回归误走兜底。**不改变运行时行为**（release 下 `assert` 空操作），仅固化契约。

archived-with: 2026-08-03-relay-t5-tail-cleanup
status: final
---

## C. 进程 / 可见性收紧（⑥b / ⑥c）— 局部低风险

### ⑥b ProxyBridge 子进程回收

`relay-dialout/.../ProxyBridge.terminate()` 现调 `process.terminate()` 但无 `waitUntilExit()` → 子进程成僵尸。补 `waitUntilExit()` 回收。

- **进程安全铁律（硬约束）**：只对 `ProxyBridge` 自己持有的 `process` 句柄操作（精确 PID），**绝不引入 `pkill` / 宽匹配 / 按名杀**——避免误杀 desktop 私有 server。既有注释已声明此铁律，本改动不得违背。
- **能耗**：`waitUntilExit()` 是终止收尾时的一次性同步等待，非轮询、非常驻线程；进程已被 `terminate()` 请求退出，等待即刻返回，收尾即止，符合「主动断开=终态」。

### ⑥c SecureSession.init 收窄 internal

构造点（origin/master `git grep "SecureSession("`）：
- 生产：`Handshake.swift:267`（dev）、`:291`（iPad）——**均包内**，收窄为 `internal` 后照常。
- 测试：包内 `SecureSessionTests.swift:13/14` + 跨包 iOS `RelayTransportTests.swift:26/27`。

**方案**：`public init` → `internal init`；两个测试文件加 `@testable import RelayProtocol` 取得 internal 访问。理由：不新增任何生产/测试面 API（对比「包内测试工厂」会新增测试专用符号）。收窄后杜绝「包外越过握手直接构造会话」。build 阶段验四端编译。

archived-with: 2026-08-03-relay-t5-tail-cleanup
status: final
---

## D. spec 级行为升级（⑥a / ⑥d）— 安全 + 能耗分析

### ⑥a 加密帧类型标签 + AAD 认证整个 header

**现状**（origin/master `SecureSession.seal`）：`AES.GCM.seal(plaintext, using: key, nonce: nonce)` —— **不传 AAD**。`sender`/`counter` 经 nonce 隐式绑定（`nonce[0]=发送方`、`nonce[4..11]=counter`，篡改→解密失败）；但 `v`/`keyEpoch`/`sessionId` 是纯明文 header，**未进 tag**，篡改仅靠路由/选密钥副作用「碰巧失败」，非设计 fail-closed。

**决策（用户确认 2026-08-03）**：
1. `SecureEnvelope` 增显式帧类型字段 `kind: RelayFrameKind`（`UInt8`-backed `enum`，明文 header，与 `sender`/`counter` 同层）。不复用 `v`（`v` 是加密版本，语义不同不应过载）。
2. 首次引入 AES-GCM AAD = **整个明文 header 的确定性规范编码**（`v` ‖ `keyEpoch` ‖ `sessionId` ‖ `sender` ‖ `counter` ‖ `kind`，固定字段序、固定端序，收发双方逐字节一致构造）。`seal` 与 `open` 均传相同 AAD。
3. 接收端以 `kind` 驱动分发，替代按 JSON 形状隐式推断帧种。`kind` 的具体 case 集在 build 阶段从现有 `SecureEnvelope` 消费点的隐式分支枚举得出（候选：应用数据 / 安全控制信令）。

**fail-closed 两层**：
- *decode 层*：收到未定义 `kind` raw value（或缺失/非法）→ 拒帧，不误当任一已知类型，不崩溃。
- *AEAD 层*：中间人篡改 `kind`（或 `v`/`keyEpoch`/`sessionId`）→ 接收端以被篡改值重建 AAD → tag 校验失败 → `AES.GCM.open` 抛错 → `SecureSessionError.decryptFailed`。

**安全分析**：
- *帧类型混淆*：不同 `kind` 有互斥、明确处理路径；未知类型不回退到任一已知路径（decode fail-closed）；`kind` 进 AAD → 篡改被 AEAD 挡下，杜绝「把类型 A 帧冒充类型 B」通道。
- *AEAD 绑定不削弱*：`kind` 与既有 `sender`/`counter` 的 nonce 绑定、单调计数重放防护正交叠加；AAD 认证是**增强**（把原本未认证的 header 字段一并纳入），不改 nonce 构造、不改密钥调度，每种 `kind` 的解密/计数校验一致生效。
- *顺带闭合缺口*：`v`/`keyEpoch`/`sessionId` 从「碰巧失败」升为显式 fail-closed。范围略超「仅 kind」，但同一 AAD 机制、零额外风险、app 未上线无兼容负担（用户已确认此加宽）。
- *零知识*：relay 不解析 `kind`，仅透传密文帧；标签在 E2E 密文之外的明文 header，relay 无法据此还原任何明文。

**能耗分析**：纯判别 + 一段 AAD 字节拼接，无新增连接/轮询/定时器。

### ⑥d relay 对端未连接时的有界缓冲

**现状**（origin/master `RelayRooms.forward`）：`// TODO(探路阶段): 对端未连接时直接丢弃` —— `target?(frame)`，对端槽空即丢。

**决策（用户确认 2026-08-03）**：
1. `RelayRooms` 的 `Room` 结构为「当前缺席对端」方向维护有界 FIFO（存不透明 `String` 密文帧）。`forward` 时对端槽空 → 入队（原丢弃改为缓冲）；`join` 成功后按 FIFO 原序 flush 给新入槽 sink，再恢复实时转发。
2. **硬上限**（新常量，置于 `RelayLimits` 旁，与既有 `maxMessageBytes`/`maxRooms` 同处）：每房间待投递缓冲 **帧数 ≤ 64 且 总字节 ≤ 512 KiB**，各自封顶。worst-case 内存 = `maxRooms`(500) × 512 KiB ≈ 256 MiB，有界。
3. **超限策略 reject-newest**：达任一上限即停止入队、丢弃新帧（O(1)，队满直接拒）。保留已缓冲前缀的因果序。
4. 缓冲存活于 `Room`；`leave` 两端皆空回收房间时随 `Room` 一并释放。

**flush 顺序正确性**：`join` 与 `forward`/`leave` 在 NIO 多连接下并发，现有 `NSLock` 保护 `rooms`。flush 须在持锁临界区内**快照并摘走**该方向缓冲（置空），锁外再逐帧投递，避免：(a) flush 期间新 live 帧插到缓冲帧之前破坏顺序；(b) 持锁调用 sink 造成重入/长临界区。摘走后新到 live 帧走实时路径（对端已在槽内），顺序自然衔接在 flush 尾部之后。

**安全分析（DoS 首要）**：
- relay 是**未认证公网入口**；无界缓冲 = 内存放大攻击（一端狂发、对端永不加入 → OOM）。故上限为硬约束；reject-newest 使攻击者狂发也只被廉价拒绝（无可放大的 memmove/弹出搬移），零额外 CPU 代价。
- 缓冲占用受 per-room 上限 × `maxRooms` 双重封顶；随房间回收释放，不泄漏。
- 零知识不破坏：只缓存不透明密文 `String`，不解析/不还原。
- 不改变既有不变量：connId 房间绑定、后到拒绝（`join` `.rejectedRoleOccupied`）、精确 `leave`（connId 匹配才清）均不受缓冲影响。

**能耗分析**：缓冲为被动持有——无定时器轮询、无空转线程；flush 由 `join` 事件驱动（非轮询）；上限防止内存长期占用。符合「静态挂起≈0 成本」。超限 reject-newest 亦无后台清理任务。

archived-with: 2026-08-03-relay-t5-tail-cleanup
status: final
---

## 主要风险

| 风险 | 缓解 |
|---|---|
| 误删活代码（A 组） | `git grep origin/master` 已核实零调用方（①②）；四端全量测试回归 |
| ⑤a 断言写错成假绿 | 符号已定（`.fullVerification`）；build 阶段以实际构造点复核再断言 |
| ⑥c 收窄破坏跨包测试编译 | `@testable import RelayProtocol`；build 阶段验四端编译 |
| ⑥a 帧类型混淆 / 削弱 AEAD | decode + AEAD 两层 fail-closed；AAD 认证整 header；方向绑定/重放回归测试 |
| ⑥a AAD 收发不一致 → 全体解密失败 | 收发双方共用同一 AAD 规范编码函数（单一实现源）；已知类型端到端往返测试兜底 |
| ⑥d 内存 DoS | per-room 硬上限（帧数+字节）× `maxRooms` 双封顶 + 房间回收释放；flood 测试证明有界 |
| ⑥d flush 顺序错乱 / 锁重入 | 持锁快照摘走、锁外投递；按序投递测试 |

## 测试策略

- **⑥a**：已知 `kind` 正常分发往返；未知/非法 `kind` raw → 拒帧且不崩溃；篡改 `kind`（及 `v`/`keyEpoch`/`sessionId`）→ `open` 抛 `decryptFailed`（AAD 回归）；方向绑定 + 单调重放不变量对每种 `kind` 回归。
- **⑥d**：对端未连接缓冲后 join 按序全投；flood 至上限 reject-newest 不无界增长（内存/计数有界断言）；房间回收释放缓冲；零知识（只密文、不解析）。
- **⑥b**：`terminate()` 后子进程被回收（无僵尸）；只操作自身 `process` 句柄、无宽匹配。
- **⑤a/⑤b**：TLS 完整校验断言；TOFU 兜底不变量断言。
- **收尾**：四端全量测试全绿（RelayProtocol / relay-dialout / relay-server / iOS）+ `openspec validate relay-t5-tail-cleanup --strict` + 安全回归（⑥a fail-closed/AEAD、⑥d 内存有界/零知识、⑥b 进程铁律）。

## Non-Goals

- 不动 relay 握手 / E2E 加密核心（密钥调度、nonce 构造、X25519/Ed25519）、配对、重连逻辑。
- 不涉及 SSH（已移除）。
- TOFU `rememberedIdentity` 损坏静默回落**不在范围**——已由 `relay-security-hardening-2` F4 修为 `recordCorrupted` 三态 fail-closed。
