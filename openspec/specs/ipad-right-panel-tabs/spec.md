# ipad-right-panel-tabs Specification

## Purpose
TBD - created by archiving change ipad-right-panel-tabs-file-browser. Update Purpose after archive.
## Requirements
### Requirement: 右边栏 tab 容器

右边栏 SHALL 由 tab 容器承载，提供顶部 tab 切换条，用户可在多个面板间切换。当前提供「审查」与「文件」两个 tab。

#### Scenario: 显示 tab 切换条
- **WHEN** 右边栏可见
- **THEN** 顶部 SHALL 显示 tab 切换条，包含「审查」与「文件」两个可选项
- **AND** 默认选中「审查」tab

#### Scenario: 切换到文件 tab
- **WHEN** 用户点击「文件」tab
- **THEN** 容器 SHALL 渲染文件浏览面板
- **AND** 隐藏审查面板内容

#### Scenario: 切换回审查 tab
- **WHEN** 用户在文件 tab 时点击「审查」tab
- **THEN** 容器 SHALL 渲染审查面板
- **AND** 审查面板的行为（本轮/全量数据源切换、逐行 diff 展示）与容器化之前一致

### Requirement: 审查面板归位为首个 tab

审查面板 SHALL 作为 tab 容器内的第一个 tab，其原有功能保持不变。审查专属的「本轮/全量」数据源切换 SHALL 保留在审查 tab 内部，不上提到容器层。

#### Scenario: 审查 tab 内数据源切换
- **WHEN** 用户在审查 tab 内切换「本轮/全量」数据源
- **THEN** 审查面板 SHALL 按所选数据源展示对应 diff
- **AND** 该切换不影响文件 tab

### Requirement: 右栏 tab 入口在窄宽下全部可达

右栏 tab 切换条 SHALL 在任意可用宽度（含窄至 320pt 的右列/全屏窄窗）下保持**全部 tab 入口可见且可命中**，SHALL NOT 因单个标签请求无限宽而占满布局、裁剪掉后续 tab 入口。当宽度不足以并排容纳所有标签文字时，切换条 SHALL 以可容纳的方式呈现（如等分压缩、横向滚动、或文字降级为图标），使每个 tab 仍可被触控点击、指针点击与外接键盘聚焦激活。

尾部的全屏/收起入口 SHALL NOT 挤占 tab 入口的可命中区域。

#### Scenario: 320pt 宽下三个 tab 均可见可命中
- **WHEN** 右栏（或右栏全屏）渲染在 320pt 宽度
- **THEN** 「审查」「文件」「侧聊」三个 tab 入口 SHALL 全部可见
- **AND** 每个 tab 入口 SHALL 可被点击并切换到对应面板（无入口被裁剪到不可命中）

#### Scenario: 尾部全屏入口不裁剪 tab
- **WHEN** tab 切换条与尾部全屏/收起入口同处一行且宽度紧张
- **THEN** 全屏/收起入口 SHALL 保留可命中
- **AND** 三个 tab 入口 SHALL NOT 因让位给全屏入口而被裁剪不可命中

### Requirement: 分屏中间档右栏据实展开（消除死按钮）
自绘三栏窄窗降级 SHALL 记录「最后请求侧」：当 app 窗口宽度落在 center+right 可容纳档（≥494pt 且 <668pt）、且用户同时想要左右栏时，SHALL 按最后请求侧展开对应单侧，不得无条件保左丢右导致右栏入口静默失效。全屏宽度（≥668pt）SHALL 三栏均按用户意图展示。

#### Scenario: 中间档最后点右则展开右栏
- **WHEN** app 窗口宽度在 [494,668)、左右栏都被想要、且用户最后请求的是右栏
- **THEN** 展开右栏（收起左栏），右栏入口生效而非静默失效

#### Scenario: 中间档最后点左则展开左栏
- **WHEN** app 窗口宽度在 [494,668)、左右栏都被想要、且用户最后请求的是左栏
- **THEN** 展开左栏（收起右栏）

#### Scenario: 全屏宽度三栏齐全
- **WHEN** app 窗口宽度 ≥668pt（如 iPad Pro 11" 全屏竖 834 / 横 1194）
- **THEN** 左中右三栏均按用户意图展示，不触发窄窗降级

### Requirement: 紧凑宽度右栏保持可达
窗口宽度低于 494pt、右栏无法与中栏并排时，打开右栏 SHALL 以 trailing overlay 呈现，不得静默吞掉请求。覆盖层宽度 SHALL 受容器约束，顶部右栏按钮 SHALL 仍可关闭它。

#### Scenario: 320pt 打开右栏
- **WHEN** 窗口宽 320pt 且用户请求打开右栏
- **THEN** 右栏以覆盖层显示，并保留一部分中栏上下文，无水平溢出

#### Scenario: 隐藏右栏首次点击即聚焦
- **WHEN** 中间档同时保留左右意图、当前显示左栏，用户点击右栏按钮
- **THEN** 首次点击即把最后请求侧切为右并显示右栏，不要求二次点击
