## ADDED Requirements

### Requirement: 左栏按「项目 / 对话」分区列出并恢复已有对话
iPad 客户端 SHALL 经 `thread/list` 拉取 Mac 上的对话线程，复刻 Codex desktop 左栏结构——以**启发式**将线程分为「项目」类（按 git 仓库根 / `cwd` 归组的可折叠文件夹）与「对话」类（无项目归属的游离会话扁平列出），并支持 `thread/resume` 恢复，包括本地 Codex 桌面 app 创建的会话。

> 说明：desktop 的项目/对话分类依赖其客户端私有字段 `workspaceKind`，该字段不在 app-server 协议；v1 用启发式近似（分类规则见设计文档 D8），本地覆盖 / 手动移动留 v2。

#### Scenario: 项目类会话归入可折叠项目分组
- **WHEN** 连接进入 ready 状态且 `thread/list` 返回的线程含 `gitInfo` 或 `cwd` 落在某 git 仓库根
- **THEN** 客户端将其归类为「项目」类，按 git 仓库根 / `cwd` 归组（同 `gitInfo.originUrl` 的多 worktree 并为一个项目）
- **AND** 左栏「项目」区以**可折叠分组**（文件夹名取用户 label ?? `cwd` 末段目录名）展示，组内对话条目显示标题与相对时间

#### Scenario: 游离会话归入「对话」区
- **WHEN** 某线程 `cwd` 为 home（`~`）或匹配不到任何项目根
- **THEN** 客户端将其归类为「对话」类，扁平展示于左栏底部独立的「对话」区

#### Scenario: 仅单项目时平铺
- **WHEN** 经分类后项目数少于 2
- **THEN** 左栏不分「项目区 / 对话区」，平铺为单一列表（复刻 desktop flat 行为）

#### Scenario: 项目分组折叠状态持久化
- **WHEN** 用户折叠或展开某个项目分组
- **THEN** 该折叠状态被本地持久化，重启 app 后保留

#### Scenario: 排序按最近更新
- **WHEN** 左栏渲染项目、项目内会话、对话区会话
- **THEN** 各列表均按线程 `updatedAt` 倒序排列

#### Scenario: 恢复桌面 app 创建的会话并渲染历史
- **WHEN** 用户在左栏选中一个由本地 Codex 桌面 app 创建的对话
- **THEN** 客户端以 `thread/resume`（by `threadId`）加载该会话
- **AND** 客户端捕获 `thread/resume` **同步响应中携带的历史 turn**（`thread.turns[].items[]`）并灌入会话状态，使历史对话（正文 / 命令输出 / 文件 diff）在中栏渲染，而非仅依赖后续通知

#### Scenario: 桌面来源会话可见
- **WHEN** `thread/list` 的默认 `sourceKinds` 未包含桌面 app 来源
- **THEN** 客户端显式传入覆盖桌面 app 来源的 `sourceKinds`，确保桌面会话出现在列表

### Requirement: 新建对话
iPad 客户端 SHALL 支持新建对话线程。

#### Scenario: 新建对话
- **WHEN** 用户发起新对话
- **THEN** 客户端以 `thread/start` 创建新线程并进入对话详情

### Requirement: 待批准状态徽标
左栏对话条目 SHALL 在该对话存在未决审批请求时显示「等待批准」状态徽标。

#### Scenario: 显示等待批准徽标
- **WHEN** 某对话收到尚未处理的审批请求
- **THEN** 该对话在左栏的条目显示「等待批准」徽标
- **AND** 审批被处理或被他端解决后徽标消失

### Requirement: 项目分组需注意计数徽标
项目分组 SHALL 在分组行显示该组内「需注意」会话数徽标，复刻 desktop「需注意计数」语义而非会话总数；计数为 0 时不显示。

> 说明：desktop 完整语义为 运行中 / 待批准 / 待响应 / unread。v1 计数仅覆盖**待批准**（复用现有 pendingApproval 状态）；运行中 / 待响应需跨会话 turn 状态跟踪（全局通知广播）、unread 需本地已读状态，统一留 v2。

#### Scenario: 分组显示待批准计数
- **WHEN** 某项目分组内存在一个或多个待批准会话
- **THEN** 该分组行显示等于组内待批准会话数的数字徽标
- **AND** 组内无待批准会话时不显示该徽标
