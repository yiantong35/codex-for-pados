# 设计

`WorkspaceToolbar.toolbarLabel` 删除 `@ScaledMetric`，改为 `.font(.system(size: 21, weight: .regular))`。`selected` 不再参与字重计算，仅保留颜色差异。保留 `.frame(width: 44, height: 44)` 与 `contentShape(Rectangle())` 作为内容命中保障；最终 toolbar 外框由 UIKit 原生 Toolbar 管理，不新增自绘 chrome。回归测试验证源代码不含动态缩放/选中字重，并验证固定字号与 regular 字重。
