## ADDED Requirements

### Requirement: 开发机 dialout 物理断线自动重拨

开发机 `relay-dialout` SHALL 作为受监督的长驻进程运行。relay WebSocket 因网络抖动、relay 重启或已升级连接空闲回收而关闭时，dialout MUST 使用带抖动且有硬上限的指数退避重拨，并在连接成功后重置失败计数；MUST NOT 要求用户手工重新启动命令。瞬时 relay 断开期间，本地 bridge 子进程 MAY 保持，应用状态恢复仍由连接成功后的 app-server resume 完成。

用户 SIGINT/SIGTERM、明确的信任拒绝、bridge 子进程终止属于终态，MUST 停止重拨并精确回收本进程创建的资源。重拨循环 MUST 可取消、不得忙等、不得宽匹配终止其它进程。

#### Scenario: relay 空闲回收后自动恢复 dev peer
- **WHEN** iPad 长时间离线导致 relay 回收 dev WebSocket，随后 iPad 再次连接稳定 sessionId
- **THEN** dialout 已自动重拨并重新占据 dev peer，受信任握手可恢复，无需人工重启

#### Scenario: 瞬时失败采用封顶退避
- **WHEN** relay 连续不可达
- **THEN** dialout 按带 jitter 的指数退避尝试，间隔增长到硬上限后封顶，不产生高频连接循环

#### Scenario: 用户退出是终态
- **WHEN** 用户向 dialout 发送 SIGINT 或 SIGTERM
- **THEN** 当前连接与自有 bridge 被回收，监督循环结束且不再重拨
