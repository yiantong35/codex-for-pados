## 1. 顶栏重排（workspace-layout）
- [x] 1.1 顶部固定全局工具栏按钮重排：左面板 · 下面板 · 右面板 · 摘要(`:≡`) · 设置（去前进/后退）
- [x] 1.2 inspector/摘要图标改用 Codex 真实 panel-right SVG（描边=关 / 填充=开）

## 2. 摘要悬浮浮层（workspace-layout / session-management）
- [x] 2.1 摘要从占列 inspector 改为 `:≡` 触发的悬浮浮层（内容自适应，非整列）
- [x] 2.2 摘要 P0 内容：diff 行数统计（turn/diff/updated 端侧算行）/ cwd / 进度(turn/plan/updated) / 任务(commandExecution 列表)
- [x] 2.3 空态（无内容时浮层占位）

## 3. 右边栏占位（workspace-layout）
- [x] 3.1 右边栏整列容器：toggle 显隐（右面板按钮）+ 空态占位
- [x] 3.2 右边栏可拖改宽 + 最小宽度

## 4. 下边栏占位（workspace-layout）
- [x] 4.1 下边栏底部容器：toggle 显隐（下面板按钮）+ 空态占位
- [x] 4.2 下边栏可拖改高 + 最小高度

## 5. 面板框架抽象
- [x] 5.1 抽象统一的"可显隐 + 空态 + 可拖 + 最小尺寸"面板容器，供右栏/下栏复用，后续 change 往里填内容

## 6. 验收
- [ ] 6.1 模拟器自检：顶栏 5 按钮各自 toggle 对应面板显隐；摘要浮层显 P0 内容；右栏/下栏 空态+可拖+最小尺寸（拖动手势靠 UI 测试或用户确认）
- [ ] 6.2 真机验收（follow-up，沿用 v1 延期约定）
