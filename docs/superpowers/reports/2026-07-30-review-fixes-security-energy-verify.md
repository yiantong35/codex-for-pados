# Verification Report — review-fixes-security-energy

- **Date**: 2026-07-30
- **Change**: `review-fixes-security-energy`
- **Phase**: verify (full mode — >3 tasks, 4 capabilities, >4 files)
- **Branch**: `worktree-feature+20260730+review-fixes-security-energy`（base `b28103cb`）
- **Result**: PASS

## 范围

一次收口 8 个 code-review 发现（4 安全 fail-open + 4 能耗/生命周期）：

| # | 类别 | 缺陷 | 修复要点 |
|---|------|------|----------|
| #1 | 安全 | OSC52 远程剪贴板无节制写入 | 设置开关 `allowRemoteClipboardWrite`（默认 OFF）+ 单次 64KB 上限 |
| #2 | 安全 | DialoutContext 信任落盘前先发布 session | 先持久化再发布，去 `try?`，落盘失败不发布 |
| #5 | 安全 | RelayE2EKeyManager 先缓存后落盘 | 方案 A `saveKeyThrowing`（协议扩展默认实现，SSH KeyManager 零改动）；落盘失败不缓存不配对 |
| #8 | 安全 | DevKeyStore 既有密钥宽权限 | 加载即收紧 0600 + 属主校验 + 拒软链，三态 fail-closed |
| #3 | 能耗 | ConversationStore 空闲 30Hz 空转 | 空闲无周期唤醒；活跃约 30Hz 攒批；stopObserving 冲刷尾字 |
| #4 | 能耗 | QRScanner 相机 start/stop 竞态 | desiredRunning 对齐，dismantle 后不残留会话 |
| #6 | 能耗 | 侧栏首拉后无条件重启轮询 | 首拉后 `guard !Task.isCancelled && connection.foregroundActive`（见下 Divergence） |
| #7 | 能耗 | 在途首连退后台不暂停 | attempt-token 作废 + take-and-nil 关闭取消；回前台自动重连 |

## 测试证据（本 session，全部在最后一个 .swift 提交 d1aa8f9b 之后采集）

- **RelayProtocol**：34 tests 全绿
- **relay-dialout**：39 tests 全绿
- **relay-server**：29 tests 全绿
- **mac-daemon / RelayDialoutCore**：涉及项全绿（0 回归）
- **iOS（CodexRemoteTests）**：164 tests 全绿（iPad-Test 模拟器）
- **xcodebuild analyze**：EXIT=0（无告警）
- d1aa8f9b 之后仅有 docs/spec/tasks/plan 提交（0 个 .swift 变更）→ 绿证据仍新鲜，满足 verification-before-completion Iron Law。

### 针对性单测覆盖（delta spec scenario → test 映射，全部存在且通过）

- #1：ClipboardPolicyTests ×3（关/开+超限/读方向 nil）+ SettingsSectionTests `.privacy` 断言
- #2：DialoutContextTrustTests `trustPersistFailureDoesNotPublishSession`
- #5：RelayE2EKeyManagerTests `testIdentityKeyThrowsAndDoesNotCacheOnSaveFailure`
- #8：DevKeyStoreTests `devKeyStoreTightensLoosePermissionsOnLoad` / `devKeyStoreRejectsSymlink` / `devKeyStoreRejectsOwnerMismatch`
- #3：ConversationCoalesceSchedulingTests `test_idle_no_periodic_wakeups` / `test_active_deltas_flush_within_one_cycle` / `test_stopObserving_flushes_tail`
- #4：QRScannerLifecycleTests ×3（reconcile；device-only 相机测试已接受为设备侧验收）
- #6：ProjectsPollingTests ×4，含 `test_startPolling_skips_when_not_visible`
- #7：SessionsManagerTests `test_appForegroundReconnectsActiveDisconnectedSession` / `test_appForegroundDoesNotReconnectActiveConnectingSession`

## Code Review（两路并行 reviewer，本 session）

- **安全线**：clean（无 Critical/Important）。
- **能耗线**：With fixes — 修复了两处确实削弱 change 目标的问题：
  - **#6**：`.task(id:)` 闭包持有启动时 View 快照，`await` 后读 `scenePhase` 为陈旧 `.active` → 改用实时 `connection.foregroundActive`（commit d1aa8f9b）。
  - **#7**：回前台自动重连未接线 → SessionsManager `setAppForegroundAll(true)` 对 activeSession `shouldAutoConnect` 触发 connect（commit d1aa8f9b）。
- 已接受并记录的次要项：DevKeyStore TOCTOU（本质无法在 stat/open 间完全消除，已属主+软链兜底）、#2 seal 自愈、#4 device-only 相机测试、#3/#7 minors。每条 reviewer 结论均对照真实代码核实后再行动。

## Spec Drift 处理（verify check item 6 → 用户决策 Option A）

- **漂移**：`ipad-energy-lifecycle` #6 Requirement、设计文档 line 111、proposal.md #6 原写死 `scenePhase == .active`；实现（review 更正）改用 `connection.foregroundActive`。
- **用户裁决**：Option A —
  - 设计文档新增「Implementation Divergence」节，记录 scenePhase 快照陈旧的根因与 foregroundActive 更正（commit 2e785ea9）。
  - delta spec / proposal.md 措辞同步更新为 `connection.foregroundActive`，保留「MUST NOT 依赖陈旧 scenePhase 快照」约束（commit c9ac7cc1）。
  - `openspec validate review-fixes-security-energy --strict` → valid。
- **#7 无漂移**：`relay-e2e-transport` #7 scenario「回前台重试成功」未规定触发点位置，SessionsManager 接线与之一致。

## 验收结论

- 全部 8 缺陷有针对性测试 + 全量绿；安全 fail-closed 四线守住；能耗静态生命周期分析 + 唤醒/取消断言兜底。
- 真机 Instruments Energy Log 非目标 → 真机验收项已写入 `docs/真机验收清单.md`（review-fixes-security-energy 节）。
- OpenSpec 严格校验通过；设计文档与实现一致（Divergence 已记录）。

**verify_result = pass**
