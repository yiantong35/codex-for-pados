---
change: land-connection-health
role: verification-report
verify_mode: full
result: pass
verified_at: 2026-08-04
base-ref: f6db293b90384438c6d09704d5d99e551c4c0afb
---

# Verification Report: land-connection-health

承接已归档 `connection-health-visibility`(PR #45，spec 入主库但代码从未合)，在无-SSH master(#46/#47 已合)基线上语义移植重新落地连接健康可见性能力。full 验证模式(26 tasks / 1 delta spec capability / 23 changed files)。

## Summary

| Dimension | Status |
|-----------|--------|
| Completeness | 26/26 tasks.md `[x]`；1 capability(ipad-connection-health) 1 MODIFIED requirement 全实现 |
| Correctness | 2/2 delta scenarios test-covered；四端全绿(RelayProtocol 42 / relay-server 37 / relay-dialout 41 / iOS 152) |
| Coherence | 实现符合 design.md/Design Doc；delta spec 与 Design Doc 无漂移；无 SSH 残留 |

**结论：无 CRITICAL / WARNING / SUGGESTION。Ready for archive。**

## Full-Verification 7 项检查

1. **tasks.md 全完成** ✓ — 26/26 `- [x]`（含 5.5 UI 基线：离线可验部分已过[横竖屏截图空态布局无错乱]，断线三态横幅+灰点转真机验收清单）。
2. **实现符合 design.md 高层决策** ✓ — 语义移植非 cherry-pick；peer-left 提示非判决判死权留心跳；不 bump tag；心跳前后台门控+判死重连有界退避。
3. **实现符合 Design Doc** ✓ — `docs/superpowers/specs/2026-08-03-land-connection-health-design.md` 全组件到位：RelaySignal / HeartbeatMonitor / ConnectionStore 集成 / 传输层 .peerLeft+triggerReconnect / UI 三态横幅+灰点 / relay 两端 peer-left。23 文件 744+/19-。
4. **capability spec scenarios 通过** ✓
   - S1「relay 传输断线推入可见异常态」→ `ConnectionStoreTests.test_heartbeatDeath_triggersReconnect`、`test_peerLeft_probeMiss_triggersReconnect`、`RelayReconnectTests.testBackoffReachesCapThenConnectionFailed`。
   - S2「就绪连接不误判断线」→ `ConnectionStoreTests.test_peerLeft_probeHit_ignored_staysReady`（伪造 peerLeft + 心跳回响 probe:true → 保持 `.ready`）。
5. **proposal 目标满足** ✓ — 断线可见性盲区收口（段 B 心跳探穿 / relay peer-left 核实 / 断线 UI 三态+灰点）；SSH 段（#45 的 ProxyChannel `.connectionFailed`）按用户确认丢弃，不补 relay 等价主动信号。
6. **delta spec 与 Design Doc 无漂移** ✓ — design §9 记录 `ipad-connection-health` relay 断线可见性收敛为 relay-only。**归档修正**：主 spec 该 requirement 唯一 Scenario 为 SSH-only「SSH 断线不再静默」(#45 引入、#46 移除 SSH 后遗留)，OpenSpec 合并禁 MODIFIED 丢现存 Scenario、禁同名 REMOVED+ADDED，故按 #46 范式改为 REMOVED「所有传输断线均推入可见异常态」+ ADDED「relay 传输断线均推入可见异常态」(承载两条已测 Scenario)。最终主 spec 语义等价、SSH 场景清除、两条 relay Scenario 不变，无代码/测试变更；design §9 已同步记录该 archive-time 修正。
7. **Design Doc 可定位** ✓ — 文件存在且 frontmatter `comet_change: land-connection-health`。

## 安全 / 能耗红线复核

- **防降级红线**：`test_peerLeft_probeHit_ignored_staysReady` + `RelayReconnectTests.testPeerLeftFrameEmitsPeerLeftControlWithoutDisconnect` 双证——恶意/故障 relay 伪造 peer-left 不能凭空杀健康连接，判死权全留心跳。
- **不动密码学**：`RelaySignalTests.swift:26` 断言 `RelayProtocolVersion.tag == "codexrelay-e2ee-v2"`（未 bump）。
- **零知识**：RelaySignal 仅 kind+sessionId，relay-server 只转发信令，两侧试解后 continue/return，不进 E2E 明文路径（`RelayRoomTests` 断言不含明文）。
- **无 SSH 残留**：swift diff 零 `ProxyChannel`/`ssh` 生产符号；pbxproj ProxyChannel=0；`.connectionFailed` 均为既有 relay 有界重连耗尽终态（design §4 保留，非 SSH）。
- **能耗**：`HeartbeatMonitorTests` 6/6（后台暂停/回前台补发/连续错过判死）；判死重连复用既有退避封顶 30s/6 次。

## openspec validate

`openspec validate --strict` 通过（未改 spec 结构）。

## 遗留（转真机验收清单，非阻塞）

- 断线三态横幅 + tab 灰点的真实断线态需 live relay 触发，无法离线复现 → 真机验收清单（沿用项目既定模式）。
