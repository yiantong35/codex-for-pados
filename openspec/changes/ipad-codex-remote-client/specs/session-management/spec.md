## ADDED Requirements

### Requirement: 按项目列出并恢复已有对话
iPad 客户端 SHALL 经 `thread/list` 拉取 Mac 上的对话线程，按 `cwd` 分组为「项目」展示于左栏，并支持 `thread/resume` 恢复，包括本地 Codex 桌面 app 创建的会话。

#### Scenario: 左栏按项目分组展示对话
- **WHEN** 连接进入 ready 状态
- **THEN** 客户端调用 `thread/list` 并按线程 `cwd` 将对话分组为项目
- **AND** 左栏展示「项目 → 对话」树，每个对话条目显示标题与相对时间

#### Scenario: 恢复桌面 app 创建的会话
- **WHEN** 用户在左栏选中一个由本地 Codex 桌面 app 创建的对话
- **THEN** 客户端以 `thread/resume`（by `threadId`）加载并渲染该会话历史

#### Scenario: 桌面来源会话可见
- **WHEN** `thread/list` 的默认 `sourceKinds` 未包含桌面 app 来源
- **THEN** 客户端显式传入覆盖桌面 app 来源的 `sourceKinds`，确保桌面会话出现在列表

### Requirement: 新建对话
iPad 客户端 SHALL 支持新建对话线程。

#### Scenario: 新建对话
- **WHEN** 用户发起新对话
- **THEN** 客户端以 `thread/start` 创建新线程并进入对话详情

### Requirement: 待批准状态徒标
左栏对话条目 SHALL 在该对话存在未决审批请求时显示「等待批准」状态徒标。

#### Scenario: 显示等待批准徒标
- **WHEN** 某对话收到尚未处理的审批请求
- **THEN** 该对话在左栏的条目显示「等待批准」徒标
- **AND** 审批被处理或被他端解决后徒标消失
