# relay-e2e-transport Specification

## Purpose
TBD - created by archiving change functionality-review-fixes. Update Purpose after archive.
## Requirements
### Requirement: 三端共享并执行统一 wire 消息上限

RelayProtocol SHALL 定义唯一的 wire 消息字节上限，relay-server、relay-dialout 与 iOS RelayTransport MUST 共同引用该值。WebSocket client/server decoder、分片累积器和发送端最终序列化帧检查 MUST 使用一致上限。发送端 MUST 在实际加密并序列化之后检查 UTF-8 帧字节数；超限 MUST 以可恢复错误拒绝发送，MUST NOT 依赖对端断开连接完成校验。

#### Scenario: 大于 16 KiB 且小于统一上限的消息通过 dialout
- **WHEN** iPad 发送一条最终 wire frame 大于 16 KiB 且不超过统一上限的消息
- **THEN** relay-server 与 relay-dialout 均接受并交付该消息，不因 NIO 默认 frame size 关闭连接

#### Scenario: 最终序列化帧超限在本地失败
- **WHEN** 文本或图片输入经加密和 JSON/base64 序列化后的实际帧超过统一上限
- **THEN** iOS 在写 WebSocket 前返回明确的 message-too-large 错误，连接保持可用

#### Scenario: 入站帧超限或类型错误时关闭通道
- **WHEN** iOS 收到超过统一上限的 WebSocket text 帧或任何 binary 帧
- **THEN** iOS SHALL 将其视为协议错误并关闭当前通道，MUST NOT 静默忽略后继续接收

### Requirement: relay 身份与 TOFU 命名空间 fail-closed

iOS SHALL 仅在 Keychain 明确报告记录不存在时生成新的 relay Ed25519 身份。Keychain 读取失败、非 UTF-8、非法 Base64 或非法密钥原始数据 MUST 显式失败，MUST NOT 生成或覆盖身份。Keychain 覆盖写 SHALL 先原位更新，仅在记录不存在时新增；更新或新增失败 MUST NOT 预先删除旧身份或 TOFU 记录。relay TOFU 命名空间 SHALL 为有效机器 UUID，缺失或畸形值 MUST 阻止建连，MUST NOT 回退为 relay URL。

#### Scenario: 身份读取瞬时失败
- **WHEN** Keychain 因设备锁定或瞬时系统错误无法读取已有 relay 身份
- **THEN** 建连显式失败且不保存新身份，后续重试仍可读取原身份

#### Scenario: 身份记录损坏
- **WHEN** relay 身份记录不是有效 UTF-8、Base64 或 Ed25519 原始私钥
- **THEN** 建连显式失败且损坏记录保持不变，等待用户或受控恢复流程处理

#### Scenario: TOFU 命名空间无效
- **WHEN** relay 连接配置缺失机器 UUID 或该值畸形
- **THEN** iOS 在读取配对码或建立 WebSocket 前拒绝连接，且不使用 relay URL 作为 TOFU key

### Requirement: 不可信入站流采用可检测的有界缓冲

RelayTransport 的明文入站流与控制流、JSONRPCClient 的 notification 与 server-request 多播 SHALL 使用有界缓冲。缓冲溢出 MUST 触发可检测的连接失败或有界重连，使权威状态通过重连恢复；实现 MUST NOT 静默丢弃 `turn/completed`、审批请求或其它不可合并控制事件。

#### Scenario: 慢消费者导致 notification 缓冲溢出
- **WHEN** 不可信对端持续发送事件并使任一 notification 订阅者缓冲达到上限
- **THEN** iOS 触发一次物理重连并失败在途请求，通过重连后的权威恢复收敛状态

#### Scenario: RelayTransport 明文缓冲溢出
- **WHEN** 解密后的应用帧到达速度超过唯一消费者且缓冲达到上限
- **THEN** iOS 关闭当前 WebSocket，并以明确的缓冲溢出错误失败该流或进入既有有界重连

### Requirement: RelayProtocol Linux Swift 6 可构建

RelayProtocol 及其 relay-server、relay-dialout 消费方 MUST 在受支持的 Linux Swift 6 环境通过严格并发编译。平台条件兼容代码 MUST 被版本控制跟踪，并 MUST 在真实 Linux 环境验证；macOS 条件分支通过不得替代 Linux 验证。

#### Scenario: Linux 严格并发构建
- **WHEN** 干净检出在 Linux Swift 6 上构建 RelayProtocol、relay-server 与 relay-dialout
- **THEN** `DirectionalKeys` 等 Sendable 类型成功编译，且无需工作区外的未跟踪补丁
