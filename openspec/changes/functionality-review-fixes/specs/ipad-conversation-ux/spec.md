## MODIFIED Requirements

### Requirement: 对话滚动位置感知

对话流 SHALL 以 120pt 近底阈值判断是否跟随，并对所有可见内容增长生效：新增 item、既有 item 的流式文本增长、审批卡新增/恢复、运行态指示变化。近底时内容增长 SHALL 自动滚到真实 bottom sentinel；离底时 SHALL 保持阅读位置并显示新消息入口。用户点按入口也 MUST 滚到 bottom sentinel，不能停在 last item 或审批卡上方。实现 MUST 事件驱动，不新增 timer/轮询。

#### Scenario: 流式文本增长近底自动跟随
- **WHEN** 用户距底不超过 120pt，agent delta 持续增长同一个 item 的文本
- **THEN** 对话持续跟随真实底部，即使 items.count 不变

#### Scenario: 审批卡出现时可达
- **WHEN** 审批卡加入当前线程且用户近底
- **THEN** 对话滚到审批卡之后的 bottom sentinel，卡片完整可见

#### Scenario: 离底时内容增长只提示
- **WHEN** 用户距底超过 120pt，流式文本或审批卡使内容增长
- **THEN** 阅读位置不被拉走，并显示新消息入口；点击后滚到真实底部

## ADDED Requirements

### Requirement: 图片附件异步选择不被迟到结果覆盖

Composer SHALL 取消已被新选择、删除、发送或视图退出取代的图片加载/编码任务，并在写回前校验 selection token。旧图片编码晚于新图片完成时 MUST NOT 覆盖新选择；用户删除附件后，迟到任务 MUST NOT 重新挂回附件。编码器 SHALL 在耗时阶段响应 cancellation。

#### Scenario: 快速选择后保留最后选择
- **WHEN** 用户先选 A 后快速选 B，且 A 的编码最后完成
- **THEN** Composer 最终只展示 B，A 的迟到结果被丢弃

#### Scenario: 删除期间编码不回挂
- **WHEN** 图片仍在编码时用户删除附件
- **THEN** 任务被取消或结果因 token 失效被丢弃，附件保持为空
