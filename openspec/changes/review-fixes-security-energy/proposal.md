## Why

一次跨端代码审查报告了 8 处属实缺陷（4 安全 + 4 能耗/生命周期），均已逐一在源码核验。安全类 4 处本质是 **fail-open**——信任/密钥未落盘、远端可静默写剪贴板、私钥权限不校验——直接违反项目恒定原则 `security-first-principle`（fail-closed、最小暴露）。能耗类 4 处是**不可见/空闲/后台仍在跑**——违反 `energy-awareness-principle`（后台暂停、避免空转）。这些是当前 `master`(b28103c) 全局代码的遗留缺陷，应在下一轮真机验收前统一收口。

本 change 采用**单 change 全修**（用户明确选择，见下）。虽跨安全与能耗两大主题，但 8 条均为**最小防御性收口**、无相互依赖、无协议/架构变更，集中一处便于统一对抗性 review，与历史 `relay-security-hardening` 系列做法一致。故 PRD 拆分预检结论：**不拆分**。

## What Changes

**安全 fail-closed 收口（4）**

- **#1 终端 OSC 52 剪贴板写门控**：远端终端输出中的 OSC 52（写剪贴板）当前被 `SwiftTermView.clipboardCopy` 无条件路由到 `UIPasteboard.general`，可静默覆盖 iPad 系统剪贴板（命令/地址/凭据粘贴劫持）。改为**默认忽略**，仅在新增的、默认关闭的设置开关启用后才写入，并限制单次内容大小。`clipboardRead`（读方向）维持返回 nil 不变。
- **#2 dev 侧信任落盘后再发布会话**：`DialoutContext.handleClientAuth` 当前先发布 `_session` 且置 `_pairingConsumed`，之后 `trust.trust` 才可能因 IO/权限失败；调用方（main.swift）用 `try?` 吞错后，后续 SecureEnvelope 仍命中已发布 session 启动 bridge。改为**事务性**：先持久化信任成功，再原子发布会话 + 消费口令；失败则清空握手状态、不发布。
- **#5 iPad 身份密钥落盘成功后再缓存参与配对**：`RelayE2EKeyManager.identityKey()` 在 `store.saveKey`（吞 Keychain 错）后立即缓存返回，无落盘确认；写失败则本次配对成功但重启换新身份、破坏 dev 信任。改为保存操作**可抛错**，仅持久化成功后缓存返回；覆盖旧项避免先删后加丢身份。
- **#8 dev 加载已有私钥校验权限**：`DevKeyStore` 的 `0600` 仅在新建时设置，已存在 `identity.key` 直接读取；迁移/恢复出的 `0644` 会对其他本机用户可读。加载前**校验属主、拒绝符号链接、收紧为 0600、目录 0700**，修复失败则拒绝启动。

**能耗 / 生命周期门控（4）**

- **#3 空闲会话不再 30Hz 唤醒主线程**：`ConversationStore.startCoalesceTimer` 无条件以 33ms 周期在 MainActor 空 drain，多侧聊线性叠加。改为**按需调度**——仅首个脏 delta 到达时安排一次延迟 flush，drain 后停止，下批数据再重新调度。
- **#4 扫码页相机启停竞态**：`QRScannerView` 的 `start`/`stop` 分派到两个全局并发任务无顺序保证，`stop` 因 `isRunning` 为 false 提前返回后排队的 `startRunning` 仍会启动相机。改用**私有串行 capture 队列 + desiredRunning 状态**，无条件排队 stop。
- **#6 侧栏首拉后按可见性再轮询**：`SidebarView` 的 `.task` 在 `await loadFromServer` 后无条件 `startPolling()`，期间切换标签/视图消失/进入后台会被覆盖。调用前**检查 `Task.isCancelled` 与实时前台真值 `connection.foregroundActive`**（不依赖 `.task` 闭包捕获的陈旧 `scenePhase` 快照），可见性作为轮询启动前置。
- **#7 后台暂停在途首连**：`ConnectionStore.setForeground` 仅处理已落地 transport；首连期间退后台时 `inFlightTransport` 与初始 `performHandshake` 不受影响，最长烧到 20s 超时。改为**同步状态给在途 transport**，建通道与初始握手前等前台；进行中的首连可取消并回前台重试。

## Capabilities

### New Capabilities

- `ipad-energy-lifecycle`: iPad 侧「不可见/空闲/后台不做功」的通用生命周期能耗纪律——空闲流式攒批按需调度（#3）、列表轮询以可见性/前台为启动前置（#6）。沉淀 `energy-awareness-principle` 在 UI 层的可验证要求。

### Modified Capabilities

- `ipad-bottom-terminal`: 新增终端剪贴板写方向的安全要求——远端 OSC 52 默认 MUST NOT 写系统剪贴板，仅在用户显式开启的开关下且限大小才允许；读方向维持拒绝（#1）。
- `relay-e2e-transport`: dev 侧握手 MUST 信任落盘成功后才发布会话/消费口令（#2）；iPad 身份密钥 MUST 落盘成功后才缓存参与配对（#5）；dev 身份私钥文件 MUST 校验权限/属主/软链、fail-closed（#8）；已升级连接的前台/后台能耗钩子 MUST 覆盖在途首连 transport 与初始握手（#7）。
- `relay-qr-pairing`: 扫码相机启停 MUST 经串行队列 + 目标状态编排，关闭页面后 MUST NOT 残留运行（#4）。

## Impact

**受影响代码**
- iOS：`Views/Workspace/SwiftTermView.swift`(#1)、`Stores/ConversationStore.swift`(#3)、`Views/QRScannerView.swift`(#4)、`Security/RelayE2EKeyManager.swift`(#5)、`Views/SidebarView.swift`(#6)、`Stores/ConnectionStore.swift`(#7)；新增设置开关（复用既有设置页容器）
- relay-dialout：`Sources/RelayDialoutCore/DialoutContext.swift`(#2)、`Sources/relay-dialout/main.swift`(#2 调用方去 `try?`)、`Sources/RelayDialoutCore/DevKeyStore.swift`(#8)

**不影响**
- relay 协议版本/握手语义（不 bump）；iPad→终端粘贴与远端读剪贴板方向（后者已 fail-closed）；无关重构

**测试与验收**
- 四个 Swift Package 测试 + iPad 模拟器全量测试须全绿；`xcodebuild analyze` 通过
- 能耗结论沿用「生命周期静态分析 + 本地验收清单」既有惯例，不跑真机 Instruments Energy Log（非目标）
