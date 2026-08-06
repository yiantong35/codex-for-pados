# ipad-side-chat Specification

## Purpose
TBD - created by archiving change functionality-review-fixes. Update Purpose after archive.
## Requirements
### Requirement: 每个侧聊线程只有一个会话状态所有者

每个活动侧聊 thread SHALL 只有一个 ConversationStore、一个通知消费者和一个 resume handler。SideChat 容器 MAY 保存 threadId、title 与 selection metadata，但 MUST NOT 同时维护一份隐藏 ConversationStore，再由可见 ConversationView 为同一 thread 创建第二份。切换或关闭侧聊必须释放该线程的可见订阅；再次选中通过 thread/resume 恢复权威历史。

#### Scenario: 选中侧聊不重复订阅
- **WHEN** 用户开启并显示一个侧聊
- **THEN** JSONRPCClient 中该侧聊只有一个 notification continuation 与一个 resume owner

#### Scenario: 多次切换不累积消费者
- **WHEN** 用户在多个侧聊间反复切换
- **THEN** 存活 ConversationStore 数量与当前可见会话所有权一致，不随切换次数增长
