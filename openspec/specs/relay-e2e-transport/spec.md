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

### Requirement: RelayProtocol Linux Swift 6 可构建

RelayProtocol 及其 relay-server、relay-dialout 消费方 MUST 在受支持的 Linux Swift 6 环境通过严格并发编译。平台条件兼容代码 MUST 被版本控制跟踪，并 MUST 在真实 Linux 环境验证；macOS 条件分支通过不得替代 Linux 验证。

#### Scenario: Linux 严格并发构建
- **WHEN** 干净检出在 Linux Swift 6 上构建 RelayProtocol、relay-server 与 relay-dialout
- **THEN** `DirectionalKeys` 等 Sendable 类型成功编译，且无需工作区外的未跟踪补丁
