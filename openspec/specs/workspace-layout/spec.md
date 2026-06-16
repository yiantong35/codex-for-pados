# workspace-layout Specification

## Purpose
TBD - created by archiving change ipad-workspace-shell. Update Purpose after archive.
## Requirements
### Requirement: 五窗口工作区布局与层级
iPad 客户端 SHALL 提供复刻 Codex desktop 的五窗口工作区：左边栏（项目/对话）· 中间（对话）· 右边栏（整列）· 下边栏 · 摘要（悬浮浮层）。布局层级（**本 change 翻转**）：左边栏 · 中间 · 右边栏三者为水平排布；**下边栏为全宽、最高优先级，横跨并压短左边栏 + 中间 + 右边栏全部**（不再让左边栏满高不被压）。

> 变更说明：change `ipad-workspace-shell` 原定「下边栏不压左边栏、只压中+右」。本 change 因右边栏改为系统列（见下），下边栏移到三栏 split 外层做全宽，故层级改为「下边栏压所有（含左边栏）」。

#### Scenario: 下边栏全宽压所有
- **WHEN** 下边栏处于打开状态
- **THEN** 下边栏全宽横跨左边栏 + 中间 + 右边栏，并将三者整体纵向压短
- **AND** 下边栏始终在最底部、最高优先级

#### Scenario: 横屏五窗口同时可见
- **WHEN** 横屏且右边栏、下边栏均打开
- **THEN** 上半部左边栏 · 中间 · 右边栏 同屏水平排布，下半部为全宽下边栏

### Requirement: 顶部固定全局工具栏
iPad 客户端 SHALL 在主界面顶部提供固定全局工具栏，承载面板开关与设置；该工具栏不随任何面板折叠而消失。按钮从左到右：左面板 · 下面板 · 右面板 · 摘要 · 设置（不含前进/后退）。

#### Scenario: 工具栏按钮切换对应面板
- **WHEN** 用户点击「左面板 / 下面板 / 右面板 / 摘要」按钮
- **THEN** 对应面板（左边栏 / 下边栏 / 右边栏 / 摘要浮层）在显示与隐藏之间切换

#### Scenario: 设置入口常显
- **WHEN** 处于主界面（任何面板显隐组合）
- **THEN** 顶栏「设置」入口始终可见可用

### Requirement: 摘要悬浮浮层
iPad 客户端 SHALL 以悬浮浮层（非整列）形式展示「摘要」，由顶栏摘要按钮（`:≡`）切换；内容自适应大小（有多少显多少）。摘要 P0 内容：变更 diff 行数统计、工作目录 cwd、进度（plan）、任务（命令列表）。

#### Scenario: 摘要浮层显示 P0 内容
- **WHEN** 用户打开摘要且当前会话有相应数据
- **THEN** 浮层显示 diff 行数统计（来自 `turn/diff/updated`）、cwd（`Thread.cwd`）、进度（`turn/plan/updated` 的 plan 步骤及状态）、任务（会话内 commandExecution 命令列表）
- **AND** 浮层大小随内容自适应，不占整列

#### Scenario: 摘要空态
- **WHEN** 打开摘要但无可显示数据
- **THEN** 浮层显示空态占位，不报错

### Requirement: 右边栏可显隐整列面板
iPad 客户端 SHALL 提供右边栏整列面板，支持显隐切换、可拖拽改宽、最小宽度；本期内容为占位空态（真实内容由后续 change 提供）。右边栏 SHALL 由系统检视列（`.inspector`，右侧系统列、左侧 sidebar 的镜像）托管，拖拽改宽平滑无闪屏，且不受左边栏显隐影响。

> 变更说明：原 change 用自绘 HStack 列 + `PanelResizeHandle`，拖动闪屏。本 change 改为系统检视列 `.inspector(isPresented:)` + `.inspectorColumnWidth`，由系统托管 resize（不闪）。NavigationSplitView 的 detail 第三列不能显隐，故右栏用 inspector 而非 detail 列。旧 inspector 拖不动的根因是 detail 被 VStack 包裹（塞下栏），本 change 下栏改全宽外层 safeAreaInset、不再 VStack 包 split，inspector 拖动恢复。

#### Scenario: 右边栏显隐与拖动
- **WHEN** 用户切换右面板按钮
- **THEN** 右边栏整列在显示与隐藏间切换
- **AND** 显示时可拖拽改宽，且不小于最小宽度
- **AND** 拖动改宽平滑、无闪屏（与左边栏一致），不受左边栏显隐影响

#### Scenario: 右边栏空态占位
- **WHEN** 右边栏打开且本期无真实内容
- **THEN** 显示空态占位

### Requirement: 下边栏可显隐底部面板
iPad 客户端 SHALL 提供下边栏底部面板，支持显隐切换、可拖拽改高、最小高度；本期内容为占位空态（终端等真实内容由后续 change 提供）。下边栏 SHALL 为全宽、挂在三栏布局外层（最高优先级），覆盖并压短左+中+右；其拖拽改高自绘、跟手、无闪屏。

> 变更说明：原 change 下边栏在 detail 区内只压中+右。本 change 改为外层全宽 safeAreaInset，压所有。

#### Scenario: 下边栏显隐与拖动
- **WHEN** 用户切换下面板按钮
- **THEN** 下边栏在显示与隐藏间切换
- **AND** 显示时可拖拽改高，且不小于最小高度
- **AND** 拖动改高跟手、无闪屏

#### Scenario: 下边栏全宽覆盖
- **WHEN** 下边栏打开
- **THEN** 下边栏全宽横跨左+中+右，不留任何一栏在其侧边

#### Scenario: 下边栏空态占位
- **WHEN** 下边栏打开且本期无真实内容
- **THEN** 显示空态占位

