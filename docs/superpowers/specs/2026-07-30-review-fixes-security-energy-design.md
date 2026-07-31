---
comet_change: review-fixes-security-energy
role: technical-design
canonical_spec: openspec
status: draft
---

# review-fixes-security-energy 技术设计（Design Doc）

一次跨端代码审查报告 8 处属实缺陷（4 安全 fail-open + 4 能耗/生命周期空转），均已对照 `master`(b28103c) 源码坐实。本 change 采用**单 change 全修**（用户明确选择）：8 条互不依赖、均为最小防御性收口、无协议/架构变更，集中一处便于统一对抗性 review，与历史 `relay-security-hardening` 系列一致。

- **canonical spec**：OpenSpec delta（4 capability：新增 `ipad-energy-lifecycle`；修改 `ipad-bottom-terminal` / `relay-e2e-transport` / `relay-qr-pairing`）。验收边界以 delta spec 为准（`openspec/changes/review-fixes-security-energy/specs/`），本文档只记录 build 阶段实现级决策，不重复也不改写验收场景。
- **base-ref**：master `b28103cbe20e10e3dbe1f40c54292f56be99fb46`。
- **约束**：`security-first-principle`（fail-closed、最小暴露）、`energy-awareness-principle`（后台暂停、避免空转、重连有界）；既有并发模式（`ConnectionStore` take-and-nil + attempt-token；`RelayE2EKeyManager` 镜像 `KeyManager` 的 `KeyStoring` 注入）必须兼容。

---

## 一、#1（P1 安全）终端 OSC 52 剪贴板写门控

### 现状与漏洞
`SwiftTermView.clipboardCopy(source:content:)` 把远端终端输出的 OSC 52 内容**无条件**写入 `UIPasteboard.general.string`。远端可静默覆盖 iPad 系统剪贴板 → 命令/地址/凭据粘贴劫持。`clipboardRead` 已返回 nil（读方向已 fail-closed）。

### 决策
- 新增默认关闭的设置项 `allowRemoteClipboardWrite`（复用既有设置页容器，T2 备好）。
- `clipboardCopy`：开关关 → 静默丢弃；开 → 校验单次字节 ≤ **64KB**（超限拒写、不截断）后写入。
- 上限取 64KB：正常终端复制的命令/路径/代码远小于此，足以挡住异常大 payload。
- `clipboardRead` 维持 nil；iPad→终端输入方向不动。
- **备选**：完全忽略（弃，用户要保留可选能力）；逐次写前确认（弃，终端场景弹窗轰炸）。

---

## 二、#2（P1 安全）dev 侧信任落盘后再发布会话

### 现状与漏洞
`DialoutContext.handleClientAuth`（:133-178）在首次配对路径下，先在锁内置 `_session` 并 `_pairingConsumed = true`（:161-165），**之后**才 `try trust.trust(ipadPubB64:...)`（:171）——落盘可能因 IO/权限失败。调用方 `main.swift:177` 用 `try?` 吞错，后续 SecureEnvelope 仍命中已发布 `_session` 启动 bridge → 「信任未落盘却已建通道」的 fail-open。

### 决策（事务性顺序调整）
- 调整 `handleClientAuth` 首次配对分支顺序：**先** `trust.trust` 成功，**再**在锁内原子置 `_session` + `_pairingConsumed`。
- `trust.trust` 抛错 → 清握手态（`_eph`/`_session` 保持 nil），向上抛。
- `main.swift` 调用方**去掉 `try?`**（:177），落盘失败不启 bridge。
- **trusted（受信任复连）分支语义保持不变**，仅动首次配对路径的落盘/发布相对顺序。
- **备选**：保留原顺序 + 失败回滚（弃，窗口内仍可能被 SecureEnvelope 命中，非真事务）。

---

## 三、#5（P2 安全）iPad 身份密钥落盘成功后才缓存 —— 方案 A（SSH 零改动）

### 现状与漏洞
`RelayE2EKeyManager.identityKey()`（:46-52）在 `store.saveKey`（内部 `try?` 吞 Keychain 错）后**立即缓存返回**，无落盘确认。写失败 → 本次配对成功但重启换新身份 → 破坏开发机侧 dev 信任。

### 关键约束
`KeyStoring` 协议（`KeyManager.swift:7-11`，`saveKey(_:)` 无 throws）由 **SSH（`KeychainKeyStore` / `ssh-ed25519-private-key`）与 relay 共用**。直接给 `saveKey` 加 `throws` 会波及 SSH 侧。

### 决策：方案 A（用户确认 —— SSH 后期将整体移除、都走 relay，故不碰 SSH）
- `KeyStoring` **新增带默认实现的** `saveKeyThrowing(_ value: Data) throws`：默认实现调用旧 `saveKey`（SSH 侧零改动、行为不变）。
- `RelayE2EKeychainStore` **override** `saveKeyThrowing` 为真实抛出 Keychain 写错误。
- `RelayE2EKeyManager.identityKey()` 改为 `throws`：仅 `saveKeyThrowing` 成功后 `cachedIdentity = k` 并返回。
- 覆盖旧项沿用 Keychain 既有「先删后加」（`KeychainStore.save`）——但 relay 身份为幂等复用（已存在则不重存），实际不触发删旧身份场景。
- **不动 `KeyManager`（SSH），守职责分离，防误用同一把密钥。**
- **备选 B**：直接给 `saveKey` 加 `throws` 改所有调用点（弃，波及 SSH、违反最小改动 + 职责分离）。

---

## 四、#8（P2 安全）dev 加载已有私钥校验权限

### 现状与漏洞
`DevKeyStore.writeSecret`（:58-62）仅在**新建**时设 `0o600`；`loadOrCreateIdentity`（:42-56）读**已存在** `identity.key` 不校验权限。迁移/恢复出的 `0644` 对其他本机用户可读。

### 决策（fail-closed）
- 读已存在文件前：`lstat` 拒绝符号链接（防经软链读受控外文件）、校验属主 == 当前 uid、`chmod` 收紧 0600、父目录 0700。
- 任一失败 → throw（拒绝启动），不返回宽松权限下的私钥。
- 新建仍 0600 / 目录 0700。
- **备选**：仅告警不阻断（弃，违反 fail-closed）。

---

## 五、#3（P1 能耗）空闲会话按需调度攒批

### 现状与漏洞
`ConversationStore.startCoalesceTimer`（:70-79）以 `while !Task.isCancelled { sleep 33ms; flushCoalesced() }` 常驻循环，空闲会话仍 30Hz 唤醒 MainActor；多侧聊线性叠加。

### 决策（按需调度）
- 去掉常驻 `while` 循环。
- 脏 delta 入队时：若无 pending flush → 安排一次延迟 flush（33ms）。
- `flushCoalesced` drain 后不自动续期；下批脏数据到达再调度。
- `stopObserving` 仍强制最后一次 flush 兜底（不丢尾字）。
- 空闲时对主线程零唤醒；活跃流仍约 30Hz 攒批（避免逐条 O(n²)）。

---

## 六、#4（P1 能耗/隐私）扫码相机启停串行化

### 现状与漏洞
`QRScannerView.PreviewView` 的 `start`（:42-61）/`stop`（:63-67）各自 dispatch 到 `DispatchQueue.global`，无顺序保证；`stop` 有 `guard session.isRunning else { return }` 早退。dismantle 调 stop 时若 isRunning 尚 false，早退后排队的 startRunning 仍启动相机 → 页面关闭后相机残留运行（隐私 + 能耗）。

### 决策（串行队列 + 目标态）
- `PreviewView` 持有私有**串行** `DispatchQueue` 与 `desiredRunning: Bool`。
- `start`/`stop` 只设 `desiredRunning` 目标态，并在串行队列上排一个「将实际态对齐目标态」的任务。
- `stop` **无条件排队**（不早退）。
- 保证 dismantle 后的 stop 一定排在任何先前 start 之后 → 最终态收敛到「停止」。
- **风险**：模拟器无相机 → 以 desiredRunning 对齐逻辑的状态机单测 + 真机抽验。

---

## 七、#6（P2 能耗）侧栏首拉后按可见性再轮询

### 现状与漏洞
`SidebarView.task(id: connection.phase)`（:42-49）在 `await ... loadFromServer` 后**无条件** `startPolling()`。异步期间切标签/视图消失/进后台（`.onChange(scenePhase)` 已 stopPolling），首拉返回仍重启轮询、覆盖停止。

### 决策
- `.task` 内 `startPolling` 前：`guard !Task.isCancelled && <前台活跃态>`。
- `ProjectsStore.startPolling` 自身加可见性前置，双重防护。

### Implementation Divergence（2026-07-30 code review 更正）
design/delta spec 原写死前台判据为 `scenePhase == .active`。code review（commit d1aa8f9b）证明：`.task(id:)` 闭包持有其**启动时**的 View 快照，`await loadFromServer` 返回后再读 `scenePhase` 拿到的是**陈旧的** `.active`（切后台已由 `.onChange` stopPolling，但闭包内视角未更新），首拉完成仍会误重启轮询——恰是本缺陷要堵的漏洞。故实现改用应用级前台真值 `connection.foregroundActive`（`ConnectionStore` 的 `@Observable` 属性，非闭包快照，读到实时前台态）。
- 判据语义不变：仍是「任务未取消 且 应用前台活跃」；仅把易陈旧的 SwiftUI 环境快照换成实时的应用级前台标志。
- 这是被 reviewer 验证的正确性改进；delta spec 措辞已同步更新为 `connection.foregroundActive`。

---

## 八、#7（P2 能耗）后台暂停在途首连

### 现状与漏洞
`ConnectionStore.setForeground`（:257-261）仅 `guard let transport`（已落地 transport），忽略 `inFlightTransport`。首连（`doEstablish` :270+ 设 `inFlightTransport`，后 `awaitHandshake`）期间退后台，在途 transport 与初始握手不受影响，最长烧到 20s 超时。

### 决策
- `setForeground` 同步状态给 `inFlightTransport`（不止已落地 transport）。
- `doEstablish` 建通道与初始握手前检查/等待前台。
- 退后台时进行中首连走**既有** attempt-token 作废 + take-and-nil 关闭路径取消，回前台重试。
- **风险**：与既有 take-and-nil / attempt-token 交互复杂，易引入首连回归 → build 阶段以 iOS 全量测试捕获竞态（memory：全测曾捕获双关竞态），take-and-nil 保 exactly-once 关闭。

---

## 测试与验收

- 四个 Swift Package 测试（RelayProtocol / relay-dialout / relay-server / RelayDialoutCore 涉及项）+ iPad 模拟器全量测试全绿；`xcodebuild analyze` 通过。
- 各缺陷针对性单测：
  - #1 开关关/开+超限/读方向 nil；#2 落盘失败不发布 session + bridge 不启 + 复连幂等不回归；#5 saveKeyThrowing 失败不缓存不配对 + SSH 路径不变；#8 0644/属主不符/软链三态 fail-closed。
  - #3 空闲无唤醒 + 活跃约 30Hz + 尾字不丢；#4 desiredRunning 对齐（dismantle 后不残留）；#6 后台/视图消失不重启轮询；#7 首连退后台不握手 + 回前台重试 + 不泄漏 transport。
- 能耗结论：生命周期静态分析 + 唤醒/取消路径断言兜底；真机 Instruments Energy Log 非目标，真机验收项写入本地清单。

## Migration

纯代码修复，无数据迁移、无部署编排。按 8 组独立提交（tasks 分组），每组可单独回滚。relay 协议不 bump → 新旧端兼容。

## Open Questions（design 阶段已收敛）

- #5 `KeyStoring` 是否 SSH/relay 共用 → **已确认共用**，采方案 A（新增默认实现的 `saveKeyThrowing`，SSH 零改动）。
- #7「首连退后台」取消重试 vs 挂起等待前台 → **取消 + 回前台重试**（与既有 attempt-token/take-and-nil 一致，避免半开连接空耗）。
- delta specs 拆分 → **已产出**：新增 `ipad-energy-lifecycle`（#3/#6），修改 `ipad-bottom-terminal`（#1）、`relay-e2e-transport`（#2/#5/#8/#7）、`relay-qr-pairing`（#4）。
