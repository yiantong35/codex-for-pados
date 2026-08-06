# ipad-review-panel Specification

## Purpose
TBD - created by archiving change ipad-review-panel. Update Purpose after archive.
## Requirements
### Requirement: iPad 解析 unified diff 成行级结构
iPad SHALL 提供 `UnifiedDiffParser`,把 unified diff 字符串解析为按文件分组的行级结构:每个文件含 path(及重命名旧 path)、变更类型(新增/删除/修改/重命名),每个文件含若干 hunk,每 hunk 含若干行,每行标注类型(新增/删除/上下文)、文本、旧/新行号。解析 SHALL 处理 `diff --git`、`+++/---`、`@@ -a,b +c,d @@` hunk 头、重命名、二进制(Binary files)、新增(/dev/null 旧侧)与删除(/dev/null 新侧);无法识别的内容降级为纯文本行,不崩溃。

#### Scenario: 解析单文件增删行
- **WHEN** 解析含 `@@ -1,2 +1,3 @@` 的 diff,内有 `+新增行`、`-删除行`、` 上下文行`
- **THEN** 得到 1 个文件,其行分别标注为 新增/删除/上下文,并带对应行号

#### Scenario: 解析多文件
- **WHEN** diff 含多个 `diff --git` 段
- **THEN** 解析出对应数量的文件,各自 path 与行级结构正确

#### Scenario: 新增与删除文件
- **WHEN** diff 一侧为 `/dev/null`
- **THEN** 该文件类型标注为 新增或删除

#### Scenario: 空 diff
- **WHEN** 解析空字符串
- **THEN** 得到空文件列表(不崩溃)

### Requirement: iPad 审查面板渲染文件树与逐行红绿
iPad 审查面板 SHALL 展示文件树(各变更文件 path)与选中文件的逐行 diff;新增行绿色、删除行红色、上下文行常规。选中文件树中某文件时,主区 SHALL 显示该文件的逐行 diff。

#### Scenario: 展示文件树
- **WHEN** 面板收到含多文件的 diff
- **THEN** 文件树列出各文件 path

#### Scenario: 选中文件看逐行 diff
- **WHEN** 用户点击文件树中某文件
- **THEN** 主区显示该文件逐行 diff,新增/删除行按红绿着色

#### Scenario: 空 diff 空态
- **WHEN** diff 为空
- **THEN** 面板显示空态,不显示文件树/diff

### Requirement: iPad 审查面板自适应横竖布局
审查面板 SHALL 按右栏实际宽度自适应布局:宽度 ≥ 阈值(约 520pt,真机可调)时左右并排(主区 diff + 右侧文件树);小于阈值时上下叠(文件树在上、选中文件 diff 在下)。文件树与 diff 视图组件 SHALL 在两种布局下复用。

#### Scenario: 宽栏左右并排
- **WHEN** 右栏实际宽度 ≥ 阈值
- **THEN** 布局为主区 diff(左) + 文件树(右)

#### Scenario: 窄栏上下叠
- **WHEN** 右栏实际宽度 < 阈值
- **THEN** 布局为文件树(上) + 选中文件 diff(下)

### Requirement: iPad 通用 diff 数据源
审查面板 SHALL 接收 diff 数据源参数,支持渲染本轮 turn diff(`ConversationState.turnDiff`)或全量工作区 diff(`gitDiffToRemote{cwd}→{sha,diff}`);由打开面板的入口决定数据源。面板本身与来源解耦,是渲染任意 unified diff 的通用组件。

#### Scenario: 渲染本轮 diff
- **WHEN** 从进度条入口打开面板(数据源=本轮 turnDiff)
- **THEN** 面板渲染本轮 diff

#### Scenario: 渲染全量 diff
- **WHEN** 从环境 inspector 变更按钮打开面板(数据源=全量 gitDiffToRemote)
- **THEN** 面板渲染全量 diff

### Requirement: 审查面板为纯 diff 查看器（无动作按钮）
审查面板 SHALL 为纯 diff 查看器,不含"让 AI 审查"按钮(desktop 审查面板无此按钮)、不含 git 写操作按钮(提交/推送/创建 PR)。git 操作走终端/agent skill,不在本面板。

#### Scenario: 无 AI 审查/git 写按钮
- **WHEN** 审查面板展示
- **THEN** 不提供"让 AI 审查"入口,也不提供提交/推送/创建 PR 按钮

### Requirement: 全量 diff 数据源随工作区/线程失效重取
审查面板的全量 diff 缓存 SHALL 以 `mode + cwd` 复合键失效：当选中 thread（cwd）变化时，SHALL 丢弃旧工作区的全量 diff 并按新 cwd 重新拉取，不得跨工作区复用旧缓存。cwd 为空时 SHALL 不发起请求且不崩溃。

#### Scenario: 切换 thread 后不复用旧工作区 diff
- **WHEN** 已加载工作区 A 的全量 diff，随后切换到工作区 B（cwd 变化）
- **THEN** 丢弃 A 的全量 diff，按 B 的 cwd 重新拉取并展示 B 的 diff

#### Scenario: 同 cwd 不重复请求
- **WHEN** 全量 diff 已按当前 cwd 加载，视图在同一 cwd 内重建
- **THEN** 不重复发起全量 diff 请求

#### Scenario: 无选中 thread 时不请求
- **WHEN** 无选中 thread（cwd 为空）
- **THEN** 不发起全量 diff 请求，界面不崩溃

### Requirement: diff 查看器可读性
审查面板的逐行 diff SHALL 提供：行号 gutter、长行横向滚动（不折行）、`textSelection` 可选可复制、适度上调的字号/行高。横向滚动 SHALL 只包裹 diff 正文区，不破坏面板 520 宽度阈值的横竖自适应布局与外层纵向滚动。

#### Scenario: 长行横向滚动不折行
- **WHEN** diff 某行文本超过可视宽度
- **THEN** 该行不软换行，可在 diff 正文区内横向滚动查看，外层纵向布局与横竖自适应不变

#### Scenario: 行号与可选文本
- **WHEN** 查看某文件逐行 diff
- **THEN** 每行左侧显示行号，diff 文本可被选中复制
### Requirement: 全量 diff snapshot 与审查上下文一致

全量 diff MUST 作为带 context identity 与 generation 的 snapshot 管理，identity 至少包含 cwd、threadId 与 RPC 身份；任一变化 MUST 立即使旧 snapshot 失效并重取。异步请求返回时 MUST 再次比对 identity/generation，迟到结果不得写入新工作区。由于同 cwd 的外部文件修改不一定产生可靠通知，面板 MUST 提供显式刷新入口；发起全量 AI 审查前 MUST 刷新当前 snapshot，使可见 diff 与动作上下文一致。

#### Scenario: 切线程丢弃迟到 diff
- **WHEN** 工作区 A 的 fetch 尚未完成时切到工作区 B，随后 A 结果迟到
- **THEN** A 结果被丢弃，面板只显示 B 的 snapshot

#### Scenario: 同 cwd 修改后显式刷新
- **WHEN** 同一 cwd 的文件在首次加载后再次变化
- **THEN** 用户可刷新并看到新 diff，不永久复用首次缓存

#### Scenario: 发起全量审查与展示一致
- **WHEN** 用户在 full 模式点击发起审查
- **THEN** 面板先刷新当前 context snapshot，再启动 review；不得展示旧 diff 却审查新 cwd
