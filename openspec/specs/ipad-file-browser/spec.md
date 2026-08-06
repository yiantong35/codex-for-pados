# ipad-file-browser Specification

## Purpose
TBD - created by archiving change ipad-right-panel-tabs-file-browser. Update Purpose after archive.
## Requirements
### Requirement: 只读目录树浏览

文件浏览 tab SHALL 以当前选中 thread 的 cwd 为根，展示只读目录树。目录采用懒加载：仅在用户展开某目录时才拉取其直接子项（`fs/readDirectory`）。

#### Scenario: 展开目录拉取子项
- **WHEN** 用户展开一个尚未加载的目录节点
- **THEN** 系统 SHALL 调用 `fs/readDirectory` 拉取该目录的直接子项
- **AND** 以目录/文件区分图标展示每个子项
- **AND** 已加载的目录再次展开时 SHALL 复用缓存，不重复拉取

#### Scenario: 无选中 thread 时的空态
- **WHEN** 当前没有选中 thread（无可用 cwd）
- **THEN** 文件 tab SHALL 显示空态提示，不发起 `fs/readDirectory` 请求

#### Scenario: 目录拉取失败
- **WHEN** `fs/readDirectory` 返回错误
- **THEN** 该目录节点 SHALL 展示错误态，且不影响树中其他节点

### Requirement: 文件内容只读查看

用户选中文件时，系统 SHALL 调用 `fs/readFile` 获取内容并按文本展示。系统 SHALL NOT 提供文件写入或编辑能力。系统 SHALL 在文件内容加载期间提供可见的加载反馈（如加载指示器/占位），SHALL NOT 在等待期间让预览区停留在上一个文件或空白而无任何反馈。

#### Scenario: 查看文本文件
- **WHEN** 用户选中一个文本文件
- **THEN** 系统 SHALL 调用 `fs/readFile`，将返回的 base64 解码为 UTF-8 文本
- **AND** 以等宽字体、可滚动的方式展示文件内容

#### Scenario: 打开文件时的加载反馈
- **WHEN** 用户选中一个文件、`fs/readFile` 尚未返回
- **THEN** 预览区 SHALL 显示加载指示（如 ProgressView/占位）
- **AND** 内容返回后 SHALL 以内容替换加载指示
- **AND** 加载失败时 SHALL 显示降级/错误态而非无限停留在加载中

### Requirement: 大文件与二进制降级

当文件内容超过大小上限（512KB）或判定为二进制时，系统 SHALL 显示占位提示而非渲染内容。

#### Scenario: 文件过大
- **WHEN** 选中文件解码后字节数超过 512KB
- **THEN** 系统 SHALL 显示「文件过大，不支持预览」占位
- **AND** 不渲染文件内容

#### Scenario: 二进制文件
- **WHEN** 选中文件解码后包含 NUL 字节或 UTF-8 解码失败
- **THEN** 系统 SHALL 显示「二进制文件，不支持预览」占位
- **AND** 不渲染文件内容

### Requirement: 手动刷新

文件浏览 tab SHALL 提供手动刷新入口，重新拉取当前目录内容。系统 SHALL NOT 使用 `fs/watch` 做实时监听。

#### Scenario: 手动刷新目录
- **WHEN** 用户触发刷新
- **THEN** 系统 SHALL 清除目标目录的缓存并重新调用 `fs/readDirectory`
- **AND** 以最新结果更新目录树

### Requirement: 横竖屏自适应布局

文件浏览 tab SHALL 按右栏实际可用宽度自适应布局，阈值 520pt，与审查面板一致。

#### Scenario: 宽布局
- **WHEN** 文件 tab 可用宽度 ≥ 520pt
- **THEN** 系统 SHALL 左右并排展示：目录树在左，文件内容在右

#### Scenario: 窄布局
- **WHEN** 文件 tab 可用宽度 < 520pt
- **THEN** 系统 SHALL 上下堆叠展示：目录树在上，文件内容在下

### Requirement: 文件查看器可读性
文件内容查看器 SHALL 提供：行号 gutter、长行横向滚动（不折行）、`textSelection` 可选可复制、适度上调的字号/行高。横向滚动 SHALL 只包裹文件正文区，不破坏 520 宽度阈值的横竖自适应布局与外层纵向滚动。

#### Scenario: 长行横向滚动不折行
- **WHEN** 文件某行文本超过可视宽度
- **THEN** 该行不软换行，可在正文区内横向滚动查看，外层纵向布局与横竖自适应不变

#### Scenario: 行号与可选文本
- **WHEN** 查看文本文件内容
- **THEN** 每行左侧显示 1-based 行号，文件文本可被选中复制
