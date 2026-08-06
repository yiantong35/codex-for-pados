# 验证报告：workspace-ui-review-fixes

- 日期：2026-08-04
- 变更：workspace-ui-review-fixes（外部 UI 方向 review 8 项发现收口，D1–D9）
- 验证模式：full（tasks 23 > 3；delta spec 覆盖 7 capabilities > 1；变更 31 文件 > 4）
- base-ref：`651f6eefb31a9d4ef876802f8c7c27b7d97660d5`
- 变更规模：`git diff --stat base...HEAD` = 31 files changed, 2473 insertions(+), 130 deletions(-)

## 结论

**通过（无 CRITICAL）。可进入归档。** 3 项 WARNING + 3 项 SUGGESTION 均为「实现已在、缺直接断言测试」的测试深度项，非功能缺陷；按 comet-verify「逐项接受偏差」记录接受理由如下。2 项文档漂移为轻微遗漏，非契约矛盾。

## 硬门（主窗口本会话亲验，Iron Law 证据）

| 检查项 | 命令/证据 | 结果 |
|--------|-----------|------|
| 完整测试套件 | `xcodebuild test`（ios/，iPad-Test，HEAD） | `Executed 506 tests, with 0 failures (0 unexpected)` / `** TEST SUCCEEDED **` |
| 应用构建 | `xcodebuild build`（模拟器） | `** BUILD SUCCEEDED **`，启动零崩溃，空态亮/暗/XXL 渲染正确、全中文本地化 |
| 全部任务勾选 | `openspec/.../tasks.md` | 23/23 `[x]`，0 pending |
| plan 勾选 | `docs/superpowers/plans/2026-08-04-workspace-ui-review-fixes.md` | 全部 `[x]` |
| 工作树 | `git status --short` | 空（clean） |

## 逐决策独立复核（file:line，主窗口本轮亲验，非仅采信子代理）

- **D1 侧聊状态隔离** — `ConversationView.swift:25` `bindsWorkspaceState: Bool = true`；`:87` gated state 写；`:95-97` gated onDisappear 清空；`:138-143` gated fetchFullDiff/startReview；`SideChatView.swift:72` 挂载传 `false`。✓
- **D2 重连多订阅表** — `ConnectionStore.swift:98` `resumeHandlers: [ResumeToken: ...]`；`:101/:135-136/:158-159` rejoinedTokens 去重补一次；`:131 addResumeHandler`→token / `:143 removeResumeHandler` 精确注销；`:186/:264` connect/disconnect 复位；`:427` 物理重连遍历触发。✓（非单一属性覆盖）
- **D4 窄窗降级纯函数** — `WorkspaceMetrics.swift:50 threeColumnMinTotalWidth`、`:60 columnVisibilityPlan`（`:62` 满足阈值全开 → `:68` 先收右 → `:73/:76` 再收左，option A 自动收起，非 overlay）。✓
- **D6 删除二次确认** — `TabBarView.swift:40-47` destructive `confirmationDialog` 绑 `removeTarget`；`:95` 单击仅 set removeTarget，`:44` 确认后才 `removeMachine`；`:89` `canConnect` XOR 连接/断开。✓

（D3/D5/D7/D8/D9 由验证子代理逐 Scenario→impl→test 映射，file:line 证据见下，结构性声明与本轮抽验一致。）

## 三维评分（openspec-verify-change）

| 维度 | 结论 |
|------|------|
| Completeness | 23/23 tasks `[x]`；7 capabilities / 12 requirements 全部有实现，无缺失实现。 |
| Correctness | 22 个 Scenario 全部有生产实现；16 个有直接断言测试，6 个为结构性/纯函数/harness 授权 fallback。 |
| Coherence | 设计 D1–D9 全部被实现遵循（含 D4 option A 自动收起）。2 处轻微文档漂移，非契约矛盾。 |

## 接受的非 CRITICAL 偏差（逐项记录）

WARNING（有实现、缺直接断言测试；接受理由：实现结构自证 + 均为 P3/边界或离屏 SwiftUI harness 已知失明，交互门控项已落真机验收清单 4.5）：
1. D8 空态 `RootSplitView.swift:232` `ContentUnavailableView("split.selectConversation")` 无键解析/挂载断言测试。影响：P3 空态引导，实现在位，视觉冒烟已过（本会话亮/暗/XXL）。
2. D8「点按新消息入口滚到底」`ConversationView.swift:74-76` 接线无单测（show/hide 纯逻辑已测）。影响：P3 便利项。
3. D7 会话行 button trait/键盘激活 `SidebarView.swift:104` 无直接断言（实现已是 `Button`，trait 由框架语义保证）。影响：a11y，真机 VoiceOver 验收落 4.5。

SUGGESTION（可后续 UI test 补真机命中/两步交互）：
4. D3 逐 tab 可命中未断言，以 `maxX ≤ 320.5 + allCases==3` fallback（离屏纯 SwiftUI Button 结构性失明，`RightPanelTabsLayoutTests.swift:8-17` 已记录，brief 授权）。
5. D6 二次确认仅挂载测试，未模拟「单击不删→确认才删」两步（结构由 removeTarget 门控清晰）。
6. D6 canConnect XOR 仅断言未连接支（XOR 由视图 if/else 保证）。

## 文档漂移（轻微遗漏，非矛盾，归档时随主 spec 合并即可）

- ProgressCardBar 被改（D5：`progress.step`/`progress.filesChanged` 键，en/zh 齐全）但 proposal impact 未列它——合法 D5 范围内修复，仅文档遗漏。
- tasks.md 1.1 将「setResumeHandler 归属」列为 D1 五处 gate 之一，但实现刻意**不** gate resume（D2 重构为 add/remove 多订阅，侧聊各 thread 亦需 rejoin）——D2 对 D1 的合理超越，`ConversationView.swift:133-137` 注释已说明，非缺陷，仅任务文表述滞后。

说明：以上 2 项为「实现/影响未完全被 proposal 列全」，非 comet-verify 检查项 6 的「delta spec 有内容而 design doc 未反映」型矛盾，故不触发 spec-drift 阻塞决策点。

## 安全 / 能耗（项目恒定原则）

- 安全面零触碰：生产 diff grep `relay|keychain|e2e|SecItem|transport|X25519|Ed25519|SSH|wss|host key` 新增行为空；ConnectionStore 改动仅 resume 订阅表，不涉传输/密钥/鉴权/绑定面。✓
- 能耗零回退：生产 diff 新增行无 `Timer|scheduledTimer|DispatchSourceTimer|.repeats|while true|Task.sleep`（`ConversationView.swift:148` 的 `Task.sleep` 是既有 D2 单次挂起，非本 change 新增、非轮询）。滚动感知为哨兵事件驱动、降级为纯函数，无新增常驻轮询/定时器。✓

## 关联产物可定位

- design doc：`docs/superpowers/specs/2026-08-04-workspace-ui-review-fixes-design.md`（存在，frontmatter `comet_change/role/canonical_spec` 齐）
- proposal：`openspec/changes/workspace-ui-review-fixes/proposal.md`
- delta specs：`openspec/changes/workspace-ui-review-fixes/specs/**/spec.md`（7 capabilities）
- plan：`docs/superpowers/plans/2026-08-04-workspace-ui-review-fixes.md`

## 真机验收

交互/设备门控项（VoiceOver 语义、真实指针 44pt 命中、真 Split View/Stage Manager 窄窗、软/外接键盘、语言切换、删除确认手势）已沉淀至 `docs/真机验收清单.md` 的 `workspace-ui-review-fixes` 节（6 组，逐组守 ui-adaptation-baseline 横竖屏）。
