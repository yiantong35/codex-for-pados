# Brainstorm Summary

- Change: workspace-3col-layout
- Date: 2026-06-14

## 确认的技术方案

把 `ipad-workspace-shell` 的自绘横向 resize 右栏（拖动闪屏）换成**系统托管的列**，从根本消闪；下栏改全宽外层 safeAreaInset。

- **右栏 = `.inspector(isPresented:$showRightPanel)` + `.inspectorColumnWidth(min:ideal:max:)`**
  - inspector 是 SwiftUI 给「右侧」的系统列（左 sidebar 的镜像）：系统托管 resize（平滑不闪）+ 可显隐 + 最小宽。
  - NavigationSplitView 不对称：左侧 sidebar 列可隐可拖；右侧 detail 列**不能隐藏**（columnVisibility 只控左侧），故不能用 detail 做可显隐右栏 → 用 inspector。
  - 移除自绘右栏：`PanelResizeHandle`(右用法)、`rightWidth`/`WorkspaceMetrics.resizedRightWidth`、`WorkspaceDetailRegion` 右栏部分。
- **下栏 = 整个 split 外层全宽 `.safeAreaInset(edge:.bottom)`**：压缩上推（compress，非 overlay），覆盖左+中+右；与顶栏 `.safeAreaInset(.top)` 对称。保留 `BottomPanelView` 自绘纵向拖把手 + hover/拖动变橙 + 最小高 clamp。
- **保留不回归**：顶栏 safeAreaInset 工具栏（右按钮切 inspector 显隐）、摘要 overlay + P0、橙 AccentColor、左栏选中态自渲染、左把手宽度监听高亮、SettingsMenu/composer 模型选择 `.popover`、各面板空态。

## 关键取舍与风险

- **旧 inspector 拖不动的根因 = detail 被 VStack 包裹**（为塞下栏）。本 change 下栏改全宽 safeAreaInset、**不 VStack 包 split** → inspector 拖动恢复 + 系统托管不闪。这是「消闪」与「inspector 可拖」的共同解。
- **下栏覆盖 = compress 上推**（用户确认），非 overlay。
- **风险/退路**：inspector 系统机制预期可拖+不闪；build 第一步快速 spike 确认（不被 VStack 包的 inspector 拖动 + 全开三栏不闪）。若仍异常再当场议退路（不预先锁定）。

## 测试策略

- 单测：既有不破（下栏高度 clamp、摘要派生逻辑）。
- 模拟器逐态截图自检：inspector 显隐、下栏全宽压所有、主题/选中/把手/popover 不回归。
- 拖动平滑/手势：CLI 验不了 → 用户实测（右栏拖动不闪、下栏拖高、inspector 可拖）。

## Spec Patch

- delta spec / proposal / design.md 措辞由「`NavigationSplitView` 第三列」更正为「`.inspector` 系统检视列」；语义（系统托管、可显隐、可拖、不闪）不变。
