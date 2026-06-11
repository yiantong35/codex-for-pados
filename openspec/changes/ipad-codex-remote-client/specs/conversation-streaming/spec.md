## ADDED Requirements

### Requirement: 发送指令并流式渲染回复
iPad 客户端 SHALL 通过 `turn/start` 发送用户输入，并流式订阅并渲染 `turn/*` 与 `item/*` 事件。

#### Scenario: 发送 prompt 并看到流式正文
- **WHEN** 用户在 composer 输入文本并发送
- **THEN** 客户端发送 `turn/start`（携带 `input`）
- **AND** 随 `item/agentMessage/delta` 事件增量渲染 agent 正文
- **AND** 收到 `turn/completed` 后标记该回合结束

#### Scenario: 渲染命令执行输出
- **WHEN** Codex 执行命令并流式产出输出
- **THEN** 客户端随 `item/commandExecution/outputDelta` 增量渲染命令输出面板

#### Scenario: 渲染文件改动 diff
- **WHEN** Codex 产生文件改动
- **THEN** 客户端展示文件编辑卡（文件名 + 增删行数）
- **AND** 展开后随 `turn/diff/updated` / `item/fileChange/patchUpdated` 渲染逐行红绿 diff

### Requirement: 中途控制（转向、排队、中断）
iPad 客户端 SHALL 支持在 turn 进行中转向（steer）、排队后续输入、以及中断。

#### Scenario: 转向活动 turn
- **WHEN** 某 turn 正在进行且用户提交转向输入
- **THEN** 客户端以 `turn/steer`（携带 `expectedTurnId`）注入输入

#### Scenario: 排队后续输入
- **WHEN** 某 turn 正在进行且用户提交新输入并选择排队
- **THEN** 客户端缓冲该输入，待 `turn/completed` 后以 `turn/start` 发送

#### Scenario: 转向不可 steer 的 turn
- **WHEN** 当前 turn 为 `review` 或 `compact` 类型（不可转向）
- **THEN** 客户端不发 `turn/steer`，并提示该回合不支持转向

#### Scenario: 中断进行中的 turn
- **WHEN** 用户对进行中的 turn 触发中断
- **THEN** 客户端发送 `turn/interrupt`

### Requirement: composer 输入能力
composer SHALL 支持文本、图片附件，以及模型/推理选择。

#### Scenario: 图片附件
- **WHEN** 用户在 composer 添加图片并发送
- **THEN** 图片作为 `UserInput` 的一部分随 `turn/start` 发送

#### Scenario: 调整模型与推理强度
- **WHEN** 用户在 composer 选择不同模型或推理强度
- **THEN** 该选择作为 `turn/start` 的 `model` / `reasoningEffort` 覆盖发送
