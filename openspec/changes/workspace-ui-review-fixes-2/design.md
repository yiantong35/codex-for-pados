## Context

首轮 `workspace-ui-review-fixes` 已交付并归档，其 UI 代码在 release 线 `e5144549` 引入、当前基线为 `ee22d660`（PR #50 合入后，未触碰本 change 相关 UI 面）。第二轮外部 review 逐条经本地读码核实的 10 处缺口，本质分三类：

1. **落码未接入生产 / 未接线**（#4 导航回调恒 nil、#10 阈值仅测试调用）；
2. **跨工作区共享状态污染**（#2 全量 diff 按 mode 缓存不随 cwd 失效）；
3. **质量洞**（#3 窄窗计划逻辑漏档、#5 i18n、#6 a11y、#7 tab 滚动、#8 可读性、#9 可见反馈）。

本 change 是纯 iOS SwiftUI 视图层 + Store 层修正，不触协议 / 数据模型 / 安全面。本文件给高层方向决策；逐行实现方案在 `/comet-design`（brainstorming）阶段细化。

## Goals / Non-Goals

**Goals:**

- 10 处发现全部闭合，且每处以「可验证的接入生产行为」为准（非孤立函数单测通过即算），避免重蹈首轮「函数测过但生产未接线」的过度声称。
- 纯逻辑部分（缓存失效键、列可见性档位、近底阈值、本地化键存在性）以 XCTest 锁定；接线/观感部分以模拟器+真机验收锁定。
- 守恒定原则：`ui-adaptation-baseline`（横竖屏+手势+软/硬键盘）、`energy-awareness`（事件驱动、无新增轮询/定时器）。

**Non-Goals:**

- 不碰 security / relay / E2E / transport / Keychain。
- 不重构审查/ diff 数据模型（`DiffFile`/`DiffLine`/`ReviewDiffSource` 结构不变）。
- 不改变 #9 底层 fire-and-forget 协议；UI 层使用短时提交门闩覆盖连点窗口，并同时承载反馈周期。
- 不处理 release 线上残留的已归档 `workspace-ui-review-fixes/tasks.md`（可选清理项，另计）。

## Decisions

- **D1（#2 缓存失效）**：`ReviewTabView` 的全量 diff 缓存键从 `mode` 扩为 `mode + cwd`（cwd 取自选中 thread，已能代表工作区/线程身份）。`.task(id:)` 绑复合键，cwd 变即重取；`fullDiff` 随之置空。纯状态推导，可单测。
- **D2（#3 窄窗档位）**：`columnVisibilityPlan` 引入「最后请求侧」概念——当 `wantRight` 为真或总宽落在 center+right 可容纳档（≥ 某阈值且 < 668）时，据实展开右栏，而非 `wantLeft` 一票否决。判定为纯函数，穷举档位单测。
- **D3（#4 导航接线）**：在 `RootSplitView` 把「打开右栏审查 tab」的闭包注入 `SummaryPopoverView(onOpenReview:)`，复用已存在的右栏 tab 选择状态（与 review-actions 能力现有跳转信号同源）。不新增全局状态。
- **D4（#5 i18n）**：`conv.item.unknown` 换正确本地化文案（en/zh 各自正确）；`ConnectionStore`/`FileBrowserStore` 硬编码中文改走 `String(localized:)` 并确保跟随注入 locale（与首轮 D5 注入 locale 同范式）。补一条「xcstrings 无占位假串」的守卫测试。
- **D5（#6 a11y）**：空 `Toggle` 标签补 `accessibilityLabel(skill 名)`；手势控件优先改为原生 `Button`。`ProgressCardBar` 不把整卡声明为按钮：仅 plan 展开控件与具备路由的文件统计为按钮，避免 diff-only 伪交互。
- **D6（#7 tab 滚动）**：`TabBarView` 外套 `ScrollViewReader`，活动 tab `.id(...)`，在选中变化时 `withAnimation { proxy.scrollTo(activeId, anchor: .center) }`。事件驱动，无定时器。
- **D7（#8 可读性）**：四项——(a) diff/文件行左侧行号 gutter；(b) 长行改横向 `ScrollView(.horizontal)` 不折行；(c) `.textSelection(.enabled)`；(d) 字号 caption2→body/caption 适度上调 + 行高。均为视图修饰，保持横竖屏自适应。
- **D8（#9 可见反馈）**：发起审查后显示成功或失败 inline 状态；提交开始即设置门闩，反馈 1.5 秒后释放，使底层即使立即返回也无法被快速连点重复触发。不引入轮询，不改 fire-and-forget 协议。
- **D9（#10 阈值接入）**：把生产近底判定接上 `ScrollAnchorPolicy.isNearBottom(threshold:120)`——最简事件驱动做法为把 sentinel 视图从 1pt 高改为 120pt 近底带（onAppear 即代表「进入近底 120pt」），或以底部锚的可见性等价映射到该策略函数；保持无几何轮询。具体取法在 design 阶段定，但必须让生产真正调用该策略函数（消灭死代码）。
- **D10（Review 路由隔离）**：`ConversationView` 接收可选 `onOpenReview`；仅 `bindsWorkspaceState=true` 时生效。主工作区注入 `requestRightPanel(.review)`，Side Chat 保持 nil，并由生产策略二次阻断误传。
- **D11（动态 locale）**：View 生成的错误、数字与相对时间显式传 `@Environment(\.locale)`；无 View 环境的 Store 使用 `LocaleManager.currentLocale`。不保留共享可变 formatter。
- **D12（状态与动态效果）**：机器状态以不同 SF Symbol、颜色和 VoiceOver value 三重表达；`accessibilityReduceMotion` 为真时停止闪烁和非必要面板过渡。
- **D13（紧凑右栏）**：低于 center+right 并排阈值时，列布局继续保护中栏，右栏以受容器约束的 trailing overlay 呈现；顶部右栏按钮保持关闭入口。≥494pt 继续使用既有单侧/三栏布局。

## Risks / Trade-offs

- **R1（#10 语义偏移）**：把 sentinel 从 1pt 改 120pt 会让「近底」判定更宽松，可能改变既有自动滚手感。缓解：以策略函数为单一真源 + 单测锁定阈值；真机验收横竖屏各验一遍自动滚/新消息浮标。
- **R2（#8 横滚与横竖屏自适应冲突）**：长行横滚叠加 `ReviewPanelView` 既有宽度自适应（520 阈值横竖布局）可能嵌套滚动。缓解：横滚只包 diff 文本区，外层纵向滚动/布局不变；真机验证嵌套滚动手感。
- **R3（#3 档位回归）**：改列可见性逻辑可能回归首轮 D3/D4（P1#2「右栏三 tab 全部可见」）。缓解：穷举 320/494/668/更宽档位单测，覆盖首轮既有场景不破。
- **R4（#4 状态串台）**：接线摘要→审查跳转若误用共享状态，可能重演首轮 D1 侧聊/主对话状态串台。缓解：复用只读跳转信号，不写共享 ActiveConversationHolder。
- **R5（过度声称复发）**：首轮教训——孤立函数测过≠生产接入。缓解：每条验收以「生产路径可见行为」为准，接线项必须真机/模拟器眼见。
