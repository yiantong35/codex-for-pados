# Tasks: 三列系统列布局重构

## 1. 前提验证（构建第一步，阻塞）
- [x] 1.1 spike 验证：inspector 三栏全开拖动（与 Task 2/3 合并实测；用户测后未再报闪屏，flicker 视为治好；左拖挤右耦合用户已接受 A 方案）

## 2. 右栏改 `.inspector` 系统检视列
- [x] 2.1 `RootSplitView`：中栏对话 `.inspector(isPresented:$showRightPanel){ RightPanelView }` + `.inspectorColumnWidth(min/ideal/max)`
- [x] 2.2 右面板按钮 toggle `showRightPanel`（绑 inspector isPresented）
- [x] 2.3 移除自绘右栏 resize：删 `WorkspaceDetailRegion` 右栏部分 + `WorkspaceMetrics.resizedRightWidth` + 整个 `PanelResizeHandle.swift`
- [x] 2.4 右栏最小宽 + 空态占位保留（inspectorColumnWidth + RightPanelView 空态）+ 右缘装饰把手（宽度监听拖动变橙）

## 3. 下栏改全宽外层 safeAreaInset
- [x] 3.1 下栏从 detail 区内移到整个 split 外层 `.safeAreaInset(edge:.bottom)`（不 VStack 包裹）
- [x] 3.2 下栏全宽覆盖左+中+右、压所有（布局翻转）；保留可拖改高 + 最小高 + 自绘把手 + `.move` 滑入过渡（弹出不僵硬）
- [x] 3.3 下面板按钮 toggle 全宽下栏显隐

## 4. 不回归既有能力（截图自检）
- [x] 4.1 顶栏 safeAreaInset 工具栏（左/下/摘要/右/设置）正常，右按钮切 inspector 显隐
- [x] 4.2 摘要 overlay 浮层 + P0 数据不回归
- [x] 4.3 橙 AccentColor 主题、左栏选中态自渲染、左把手宽度监听高亮不回归
- [x] 4.4 SettingsMenu + composer 模型选择 `.popover` 不回归
- [x] 4.5 各面板空态占位不回归

## 5. 验证
- [x] 5.1 单测通过（121 测试 0 失败；删 resizedRightWidth 的 4 个测试，其余不破）
- [x] 5.2 模拟器逐态自检（截图）：三列同屏、下栏全宽覆盖左右、把手对齐(~2pt)、橙主题/选中态已核对
- [ ] 5.3 用户实测确认：右栏拖动平滑不闪、下栏拖高跟手、inspector 可拖（**当前待办——迁移后续此项**）
- [ ] 5.4 真机验收（follow-up，沿用 v1/change1 延期约定）
