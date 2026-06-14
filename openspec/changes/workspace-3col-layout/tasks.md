# Tasks: 三列系统列布局重构

## 1. 前提验证（构建第一步，阻塞）
- [ ] 1.1 验证 iPad 上 `NavigationSplitView` 第三列(detail)是否用户可拖宽（最小 spike：sidebar|content|detail 三列，detail 放占位，模拟器/真机试拖）。可拖 → 继续；不可拖 → 暂停与用户确认退方案

## 2. 右栏改系统第三列
- [ ] 2.1 `RootSplitView` 改三列 `NavigationSplitView`（左 sidebar │ 中 content=对话 │ 右 detail=RightPanelView）
- [ ] 2.2 右栏显隐改由 `columnVisibility` 控制 detail 列（替代 `showRightPanel` 的 HStack 条件）；右面板按钮切换 detail 显隐
- [ ] 2.3 移除自绘右栏 resize：`PanelResizeHandle`(右栏用法)、`rightWidth`/`WorkspaceMetrics.resizedRightWidth`、`WorkspaceDetailRegion` 右栏部分
- [ ] 2.4 右栏最小宽 + 空态占位保留（`navigationSplitViewColumnWidth` min/ideal/max）

## 3. 下栏改全宽外层 safeAreaInset
- [ ] 3.1 下栏从 detail 区内移到整个 split 外层 `.safeAreaInset(edge:.bottom)`（不 VStack 包裹）
- [ ] 3.2 下栏全宽覆盖左+中+右、压所有（布局翻转）；保留可拖改高 + 最小高 + 自绘把手 hover/拖动变橙
- [ ] 3.3 下面板按钮 toggle 全宽下栏显隐

## 4. 不回归既有能力
- [ ] 4.1 顶栏 safeAreaInset 工具栏（左/下/摘要/右/设置）正常，右按钮切 detail 显隐
- [ ] 4.2 摘要 overlay 浮层 + P0 数据不回归
- [ ] 4.3 橙 AccentColor 主题、左栏选中态自渲染、左把手宽度监听高亮不回归
- [ ] 4.4 SettingsMenu + composer 模型选择 `.popover` 不回归
- [ ] 4.5 各面板空态占位不回归

## 5. 验证
- [ ] 5.1 单测通过（下栏高度 clamp、摘要派生逻辑等既有测试不破）
- [ ] 5.2 模拟器逐态自检（截图）：三列同屏、下栏全宽覆盖左右、显隐组合、主题/选中不回归
- [ ] 5.3 用户实测确认：右栏拖动平滑不闪（对照左栏）、下栏拖高跟手、detail 列可拖宽
- [ ] 5.4 真机验收（follow-up，沿用 v1/change1 延期约定）
