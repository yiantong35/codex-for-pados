# 工具栏按钮尺寸稳定性修复

## 问题

在外观「文字大小」选择“更大”后，工作区右上角刷新、面板和设置按钮的图标会在反复点击面板按钮时交替变大或变小。

## 根因

`WorkspaceToolbar.toolbarLabel` 使用 `@ScaledMetric` 缩放图标，并根据选中状态切换 SF Symbols 字重。系统 Toolbar 会根据内容重新计算最终 UIKit item 几何，导致动态字体和选中状态在重复布局中相互影响；内部 44pt frame 不是最终 toolbar chrome 尺寸。

## 修复目标

共享 toolbar label 使用固定 21pt、regular SF Symbols，选中状态仅通过 accentColor 和现有可访问性值/selected trait 表达；保留原生 ToolbarItem/ControlGroup 及系统命中区。
