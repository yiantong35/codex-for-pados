## ADDED Requirements

### Requirement: 文件查看器可读性
文件内容查看器 SHALL 提供：行号 gutter、长行横向滚动（不折行）、`textSelection` 可选可复制、适度上调的字号/行高。横向滚动 SHALL 只包裹文件正文区，不破坏 520 宽度阈值的横竖自适应布局与外层纵向滚动。

#### Scenario: 长行横向滚动不折行
- **WHEN** 文件某行文本超过可视宽度
- **THEN** 该行不软换行，可在正文区内横向滚动查看，外层纵向布局与横竖自适应不变

#### Scenario: 行号与可选文本
- **WHEN** 查看文本文件内容
- **THEN** 每行左侧显示 1-based 行号，文件文本可被选中复制
