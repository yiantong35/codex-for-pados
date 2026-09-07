## MODIFIED Requirements

### Requirement: 工具栏图标尺寸在动态文字大小下稳定

工作区刷新、四个面板和设置工具栏控件 SHALL 使用固定 21pt regular SF Symbols，不得因 Dynamic Type 或选中状态改变图标字号/字重。选中状态 SHALL 继续通过 accent color、accessibility value 与 selected trait 表达。控件 SHALL 保留原生 ToolbarItem/ToolbarItemGroup/ControlGroup；系统 toolbar 负责最终 chrome 和命中区，内部内容命中区不得小于 44×44pt。

#### Scenario: 更大文字档重复切换面板

- **WHEN** 用户将外观文字大小设为“更大”，并重复点击任一面板按钮
- **THEN** 刷新、面板、设置图标始终保持 21pt regular 外观，不交替缩放或变更字重
- **AND** 每次点击仍能命中对应按钮，选中语义通过颜色和 VoiceOver 状态保留

#### Scenario: 标准文字档与横竖屏

- **WHEN** 使用标准文字大小并在 iPad  portrait、landscape 或窄多任务宽度查看工作区
- **THEN** 工具栏继续使用系统布局，无自绘第二层 chrome、裁切或重叠，交互目标有效保持至少 44pt
