## ADDED Requirements

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
