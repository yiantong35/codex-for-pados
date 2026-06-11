# Brainstorm Summary

- Change: ipad-codex-remote-client
- Date: 2026-06-11
- 状态：进行中（增量更新，未定稿）

## 已确认事实（来自真实 codex 0.133.0 协议探查）

- `codex app-server --listen ws://IP:PORT` 与 `generate-json-schema` / `generate-ts` 在 0.133.0 真实存在。
- 客户端可调方法（MVP 相关）：`initialize`/`initialized`、`thread/list`·`resume`·`start`·`read`·`archive`·`name/set`、`turn/start`·`interrupt`·`steer`、`model/list`·`skills/list`。
- 服务端→客户端审批请求（两代）：v2 `item/commandExecution/requestApproval`、`item/fileChange/requestApproval`、`item/permissions/requestApproval`；旧版 `execCommandApproval`、`applyPatchApproval`；另有 `mcpServer/elicitation/request`、`item/tool/requestUserInput`。
- 流式事件：`item/agentMessage/delta`（正文）、`item/reasoning/textDelta`（推理）、`item/commandExecution/outputDelta`（命令输出）、`turn/diff/updated`（实时 diff）、`turn/started`·`completed`、`thread/tokenUsage/updated` 等。
- 协议原生支持 `serverRequest/resolved`（审批被其他客户端处理时通知）与 `remoteControl/status/changed`。

## 已确认决策

- **北极星目标**：完全对等本地 Codex 桌面 app 的体验。协议层面可行（同一 app-server 协议），差距只在各面板的 SwiftUI 重做工时。
- **分期策略**：架构按"桌面对等"设计（协议层一次性订阅全部事件，UI 面板可插拔），但首个可用版本先交核心。
- **v1 首交范围**：对话正文流 + turn 状态 + **完整审批**（命令/文件/权限）+ 命令输出流 + 文件 diff。
- **v2+ 延后**：推理流面板、plan、Git/worktree 编排、realtime 语音。

## 关键取舍与风险（待 Design Doc 展开）

- WebSocket 传输官方标"实验性" → pin codex 版本、从 generate-json-schema 生成类型、隔离协议层。
- 审批有两代（legacy + v2）→ v1 需明确处理哪套（待定，倾向 v2 item/* + 必要时兼容 legacy）。
- Citadel 在 iPadOS 端口转发稳定性未知 → 需技术验证 spike。
- iOS 后台 socket 限制 → 断线重连 + 依赖 thread/resume 恢复，不依赖内存态。

## 测试策略（候选，待确认）

- 协议层（JSON-RPC 编解码 + 事件归约）用单元测试 + 录制 fixture / mock app-server，可脱离真机。
- SSH 隧道 + WebSocket 集成靠 spike + 手动 E2E。

## UI 参考（来自用户提供的 desktop app 截图）

desktop app 为**三栏布局**：
- 左栏（~260）：快速对话/搜索/插件/自动化 + 「项目」树（📁 按 cwd 分组，下挂对话，条目显示标题+相对时间或状态徽标如「等待批准」⟳）+ 设置。
- 中栏：用户消息气泡 + 「已处理 Nm」+ agent 正文流 + 「正在运行 <cmd>」+ **多选项审批卡** + 文件编辑卡（+N -M / 撤销 / 审核，点开=逐行红绿 diff，语法高亮）+ 底部 composer（+ / 请求批准▾ / 模型·推理选择器 / 发送）。
- 右栏（~360）：简态 输出/来源；富态 环境信息（git 变更 +/-、本地▾、分支▾、提交或推送、检查 PR、进度☑清单、任务列表、浏览器、来源）。

**关键修正 1 — 审批是多选项非二元**：① 是 ② 是且此前缀命令本会话不再询问（对应协议 `ExecPolicyAmendment`/会话级策略放行）③ 否+反馈。审批流必须支持多选项响应。
**关键修正 2 — 三栏 iPad 适配**：横屏三列 `NavigationSplitView`；竖屏侧栏抽屉化、右栏收成 sheet。

**v1/v2+ 面板切分**：左栏（项目+对话树+状态徽标）、中栏（正文流+命令运行+多选项审批卡+文件编辑卡+逐行diff）、右栏简态（输出/来源）→ v1；右栏环境信息富态（git/进度/任务/浏览器）+ 顶部选择器完整可调 → v2+。

## Spec Patch

design 阶段创建 5 份 delta spec（mac-launcher / remote-connection / conversation-streaming / session-management / approval-flow），含验收场景。approval-flow 需覆盖：多选项审批响应、会话级前缀放行、超时/断线不自动批准、serverRequest/resolved 被他端处理。

## 已确认项（更新）

- 多项目：v1 即支持，左栏复刻 desktop 的「项目→对话」树。
- 渲染丰富度：v1 核心（正文流+turn状态+完整多选项审批+命令输出+文件diff），北极星=桌面对等，架构按对等预留（协议层订阅全事件、UI 面板可插拔）。

## 已确认项（最终）

- **审批两代**：以 v2 `item/*/requestApproval` 为主，兼容 legacy `execCommandApproval`/`applyPatchApproval`。
- **审批提醒**：v1 仅做应内「等待批准」徒标（复刻 desktop 侧栏徽标）；后台本地/推送通知放 v2。
- **composer v1**：图片附件输入（`ImageDetail`/`UserInput`）、模型/推理选择可调（映射 `turn/start` 的 `model`/`reasoningEffort`）、中途转向、引导/排队两种中途输入。
- **steer vs queue（已核实 codex 0.133.0）**：引导=`turn/steer`（注入活动 turn，带 `expectedTurnId` 前置校验；review/compact 类型不可 steer），app-server 原生支持；排队=客户端缓冲 + `turn/completed` 后 `turn/start`，无服务端方法（desktop 亦如此实现）。
- **turn/start 富参数**：per-turn 可覆盖 `model`/`reasoningEffort`/`approvalPolicy`(AskForApproval)/`approvalsReviewer`(审批路由)/`sandboxPolicy`/`cwd`，composer 选择器与审批策略均可映射。
- **测试策略**：协议层/归约层用录制 fixture + mock 传输做单元测试；SSH/WS 集成靠 spike + 手动 E2E；验收 = tasks.md 的 4 个 E2E 场景。

## 状态：已定稿（用户确认开始写 Design Doc + 5 份 delta spec）
