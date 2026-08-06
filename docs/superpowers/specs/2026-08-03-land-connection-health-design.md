---
comet_change: land-connection-health
role: technical-design
canonical_spec: openspec
archived-with: 2026-08-04-land-connection-health
status: final
---

# Design Doc: land-connection-health

> 承接已归档 change `connection-health-visibility`(PR #45)。其 spec 已入主库但代码从未合;随后 #46 删除整个 SSH 传输层,#45 分支与当前 master 结构性冲突。本 change 在**无-SSH master 基线**上重新落地连接健康可见性能力,并修正一条引用已删 SSH 的过时 spec。

## 1. 背景与输入区分

| 来源 | 角色 | 处理 |
|------|------|------|
| 主库 `openspec/specs/`(ipad-connection-health 等) | WHAT(权威) | 已存在,本 change 仅补实现 + MODIFY 一条 |
| origin 分支 `worktree-feature+20260802+connection-health-visibility`(#45,merge-base `8b778a40`,24 文件) | HOW 的旧版(基于有-SSH) | **只取逻辑 diff,禁整文件覆盖** |
| 当前 master(HEAD `27f47185`,含 #46/#47) | 移植基线 | 移植类文件以此为底叠加 delta |

**基线核查结论(逐文件已验证):** 当前无-SSH master 保留了 #45 delta 依赖的全部结构锚点,故这是一次近乎干净的语义移植,唯一失效件是 #45 的 `ProxyChannel.swift`(SSH,载体已被 #46 删)。

## 2. 核心决策:语义移植,非 cherry-pick / merge

**铁律:** 移植类文件以当前 master 版本为基线,只叠加"连接健康"delta;禁止从 #45 分支整文件覆盖,否则会带回已删的 SSH 字段/类型、撤销 #46。参考 #45 时只取其逻辑 diff。

### 2.1 文件分类(24 → 落 22 / 丢 2)

**干净加(master 无此文件):**
- `packages/RelayProtocol/Sources/RelayProtocol/RelaySignal.swift`
- `ios/CodexRemote/Stores/HeartbeatMonitor.swift`
- 新测试:`RelaySignalTests` / `HeartbeatMonitorTests` / `ConnectionBannerStateTests` / `ConnectionStoreTests` / `RelayReconnectTests` / `TabIndicatorTests` / `RelayRoomTests` / `JSONRPCClientHeartbeatCorrelationTests`

**语义移植(基于无-SSH 当前版本叠加 delta):**
- `ios/CodexRemote/Stores/ConnectionStore.swift`(最重)
- `ios/CodexRemote/Transport/{TransportControlEvent,MessageTransport,RelayTransport}.swift`
- `ios/CodexRemote/App/CodexRemoteApp.swift`
- `ios/CodexRemote/Domain/TabIndicator.swift`
- `ios/CodexRemote/Stores/SessionsManager.swift`
- `ios/CodexRemote/Views/TabBarView.swift`
- `ios/CodexRemote/Resources/Localizable.xcstrings`
- `relay-server/Sources/RelayServerCore/RelayRoom.swift`
- `relay-dialout/Sources/relay-dialout/main.swift`
- `ios/CodexRemote.xcodeproj/project.pbxproj`(注册新 iOS 源 + 测试文件;RelaySignal 在 SPM 包由 Package.swift 自动纳入)

**丢弃(用户确认"SSH 相关都不要"):**
- `ProxyChannel.swift` 的 SSH 掉线 `.connectionFailed` 改动(载体已删)
- `ProxyChannelControlTests.swift`
- ❌ 不为 relay 传输层补等价"主动掉线信号"——relay 掉线可见性依赖端到端心跳超时判死

## 3. 组件设计

### 3.1 RelaySignal(连接层信号帧)

```swift
public struct RelaySignal: Codable, Sendable, Equatable {
    public var kind: String        // "peer-left"
    public var sessionId: String
    public static let peerLeftKind = "peer-left"
}
```

- 由 relay-server 在一端离开时向仍在的对端**明文**下发,仅承载连接层事件。
- 靠 `kind` 字段与无 `kind` 的 `SecureEnvelope` 试解歧义(仿既有 `RejectHello` 范式):业务密文帧无 kind,解不成 RelaySignal。
- **不进 HKDF/握手,不 bump `RelayProtocolVersion.tag`。**

### 3.2 HeartbeatMonitor(@MainActor 端到端心跳调度器)

- `Config`:`interval = .seconds(10)`、`missThreshold = 2`。
- **纯调度 + 连续错过计数 + 前后台门控**;探针本体(`probe`)与 `sleep` 由外部注入(可测)。
- `start()` / `stop()`(幂等)。`setForeground(false)` 取消 loop(后台暂停);`setForeground(true)` 重启 loop + 立即补发一次 `probeOnce`。
- `probeOnce()`:带外单次探活,未回响即 `onUnhealthy`,有回响忽略(peer-left 核实用)。
- 判死后置 `loopTask = nil` 并 return → 使 `start()`/回前台可经 `restartLoopIfNeeded` 重启。
- **判活只看"有无回响",天然跨登录方式。**

### 3.3 ConnectionStore 集成(基于无-SSH 当前版本)

新增字段:`lastConfig`(横幅"重新连接"按钮据此以原配置重连)、`heartbeat`、`injectedHeartbeatFactory`(测试注入脚本化 monitor)。

- **探针 `sendHeartbeatProbe()`**:发 `getAuthStatus`(空 params)与 10s 超时用 `withTaskGroup` 竞速;先返回者胜,收到 JSON-RPC 回响=true。范式已存在于 `EnvironmentInspectorModel.swift:41`。
- **判死回调 `onUnhealthy`** = `transport?.triggerReconnect()`(判死 → 有界重连,复用既有退避封顶)。经 `HeartbeatUnhealthy` 结构体包装喂 `@escaping` 形参。
- **生命周期接线(control switch 各态):**
  - 首连成功 / `.ready`(重连成功)→ `startHeartbeat()`
  - `.reconnecting` / `.connectionFailed` / `.trustRevoked` → `stopHeartbeat()`
  - `disconnect()` / 后台转 `.disconnected` → `stopHeartbeat()`
  - `applyForeground(active)` → 转发 `heartbeat?.setForeground(active)`
  - **`.peerLeft` → `Task { await heartbeat?.probeOnce() }`**(非判决,核实)
- **`ConnectionBannerState`**:`needsRePairing` 为真 → `.trustRevoked`(优先);否则 `.reconnecting`→`.reconnecting`、`.failed`→`.failed`、其余 → nil(隐藏)。

### 3.4 传输层

- `TransportControlEvent`:`+ case peerLeft`。
- `MessageTransport`:`+ func triggerReconnect() async`,默认空实现(MockTransport 为 no-op)。
- `RelayTransport`:
  - 接收循环在 `SecureEnvelope(decoding:)` 解密**之前**加 peer-left 试解分支:`if let sig = try? RelaySignal(decoding:), sig.kind == peerLeftKind { emitControl(.peerLeft); continue }`。
  - `triggerReconnect() { await ws?.close() }`:丢弃当前 ws 通道使 `receiveText()` 返回 nil,因**未置** `activeClose` 且 `channelFactory != nil`,`handleDisconnect(nil)` → `reconnectLoop()`(与自然瞬断同链路)。

### 3.5 UI

- 横幅三态(`CodexRemoteApp.reconnectBanner`):`.reconnecting`(黄,无按钮)/`.failed`(红 +「重新连接」→`connection.reconnect()`)/`.trustRevoked`(红 +「重新配对」→ sheet `NavigationStack { RelayPairingImportView() }`)。
- `TabIndicator`:`+ case disconnected`(灰点,非闪烁 `isBlinking` 不含它)。
- `SessionsManager.indicator()`:已建但 `phase != .ready` → `.disconnected`;`.ready` 前提下才评估会话状态(红点仅 systemError 触发)→ **红灰严格正交**。
- `TabBarView.DotView`:`.disconnected → dot(.gray)`。
- i18n:`connection.disconnected` / `connection.trustRevoked` / `connection.reconnect` / `connection.rePair`。

### 3.6 relay 两端

- `RelayRoom.leave()`:仅当某槽被**实际清除**(connId 匹配)且另一槽仍在时,**解锁后**向仍在的对端 sink 下发 `RelaySignal(peerLeftKind, sessionId)`。锁内只置 `notifySink`,解锁后回调(sink 内部 hop 到 eventLoop,不同步重入 rooms)。**零知识:只发信令不碰密文。**
- `relay-dialout/main.swift`:dev 侧收到 `kind == peerLeftKind` 的帧静默 `return`(不据此动作,避免误入握手解析)。

## 4. 安全分析(security-first)

- **防降级红线(构造性证明):** relay 是不可信中间人。`.peerLeft` → 仅 `probeOnce()` → 唯有端到端心跳超时才 `onUnhealthy → triggerReconnect`;心跳仍回响则忽略。判死权全留心跳 → 恶意/故障 relay 无法凭空杀健康连接。
- **零知识不破坏:** `RelaySignal` 仅承载连接层事件(kind+sessionId),relay-server 只转发信令、iPad/dev 试解后 `continue`/`return`,绝不进入 E2E 明文解析路径。
- **fail-closed:** 心跳判死、传输断开一律推入可见异常 phase(不 fail-open 假装在线);`needsRePairing` 走重配路径而非静默降级。
- **不动密码学:** 不改 E2E 原语/握手契约、不 bump `RelayProtocolVersion.tag`(心跳纯活在已建立 E2E 信道内)。

## 5. 能耗分析(energy-awareness)

- **前后台门控:** 心跳前台 10s 周期;转后台 `setForeground(false)` 取消 loop(不维持前台级唤醒);回前台重启 + 补发一次。
- **无空转:** 心跳仅在 `.ready` 活跃连接上运行;空闲/断开 `stopHeartbeat`。
- **重连有界:** 判死重连复用既有指数退避(封顶 30s、最多 6 次),不无界重试。
- **事件驱动:** peer-left 被动触发一次 `probeOnce`,非轮询。

## 6. 判死延迟(可调默认值)

段 B 静默死亡 → 判死延迟 ≈ **20–30s**(前台 10s 周期 × 连续错过 2 次 + 单次探针最多与 10s 超时竞速)。**沿用已归档 change 的既定行为,默认保持**(用户已确认)。

## 7. 测试策略

| 端 | 覆盖 |
|----|------|
| RelayProtocol | RelaySignal 编解码往返 + `tag` 未变断言 |
| iOS | HeartbeatMonitor(正常维持/单次错过不判死/连续错过判死/后台暂停+回前台恢复/probeOnce/判死重启);ConnectionStore(phase 收敛/判死重连/**防降级:伪造 peerLeft + 心跳回响→保持 .ready**);ConnectionBannerState 三态;TabIndicator 红灰正交;JSON-RPC id 关联 |
| relay-server | leave 发 peer-left / 对称 / 幂等 / 不含明文 |
| relay-dialout | 优雅忽略 peer-left |

- **安全回归:** 防降级用例(恶意 relay 伪造 peer-left 不杀健康连接)。
- **能耗回归:** 后台暂停 / 回前台恢复补发。
- **UI 适配基线:** 横幅/灰点在横竖屏、外接键盘/软键盘下均正确(项目恒定原则)。

## 8. 风险与边界

- **pbxproj 手工编辑:** 易漏文件导致编译不过;移植时逐一核对 build phase 注册新 iOS 源 + 测试。
- **HeartbeatUnhealthy 逃逸包装:** 略笨重但必要(结构体存储属性天然逃逸,喂 `@escaping` 形参),保留 #45 原样。
- **peerLeft 试解误判:** 极低(密文帧无 `kind`,JSON 解码失败即 `continue`);双侧对称处理。

## 9. Spec 影响

唯一 spec delta 落在 `ipad-connection-health`,将 relay 断线可见性收敛为 relay-only 语义。**归档实现修正(archive-time)**:原计划为 MODIFY「所有传输断线均推入可见异常态」保留原标题只改内容;但归档时发现主 spec 该 requirement 的唯一 Scenario 是 SSH-only 的「SSH 断线不再静默」(#45 引入、#46 移除 SSH 后遗留未清),而 OpenSpec 归档合并**禁止 MODIFIED 静默丢弃现存 Scenario**,且**禁止同名 REMOVED+ADDED**。故按 #46(remove-ssh)既定范式改为 **REMOVED「所有传输断线均推入可见异常态」(附 Reason/Migration)+ ADDED「relay 传输断线均推入可见异常态」(relay-only,承载已实现且测试覆盖的两条 Scenario)**。最终主 spec 语义等价(relay-only、SSH 场景清除、两条 relay Scenario),仅 requirement 标题随之更新为 relay 专述;无代码/测试变更。`relay-e2e-transport`「对端离开主动通知」、`ipad-multi-connection`「tab 通知指示圆点」相关需求已在主 spec,本 change 仅补实现。brainstorming 未发现需补的验收场景,无 Spec Patch。
