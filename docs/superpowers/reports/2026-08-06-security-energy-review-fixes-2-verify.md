# security-energy-review-fixes-2 验证报告

日期：2026-08-06

## 修复范围

- 兼容上一版嵌套 relay / pairing 配置；混合损坏数组只丢弃无效项，不清空有效机器。
- peer-left 绑定当前 relay session；心跳突发合并，连续 miss 才判死，活动/后台 tab 使用 10s/60s 分级。
- 完整分页同步与 30s 最近页轮询分离；轮询失败指数退避到 5min，RPC 重绑取消旧任务。
- 用户显式断开后，切 tab 和 app 前后台不自动重连；显式连接解除暂停。
- dialout 子进程在私有串行队列内有界回收：SIGTERM 宽限后精确 SIGKILL 自身 PID，并在 NIO EventLoop 外 reap。

## 自动化结果

- `packages/RelayProtocol`: 42 tests passed。
- `relay-server`: 41 tests passed。
- `relay-dialout`: 50 tests passed；包含顽固子进程 SIGKILL/reap 覆盖。
- `mac-daemon`: 48 tests passed。
- `bash scripts/comet-verify-check.sh`: XCTest 528 + Swift Testing 155，`TEST SUCCEEDED`。
- `bash ios/comet-build-check.sh`: exit 0。
- `xcodebuild analyze`: exit 0，无本轮新增并发、任务泄漏或 actor 隔离告警。
- `openspec validate security-energy-review-fixes-2 --strict`: valid。
- 静态复核：peer-left 无游离探测 Task；列表轮询不跑完整分页；非活动 tab 不使用 10s 心跳；`waitUntilExit` 仅在 dialout 私有进程队列。

## 设备验证

- MobAI 已将最终 Debug 构建安装到 `iPad-Test`。
- MobAI 自动化桥接返回 HTTP 402 `device_limit_reached`，因此本轮无法执行 UI 启动、前后台切换和能耗指标采样；未修改用户账户中的设备注册。
- 待执行项已追加到 `docs/真机验收清单.md`。

## 已知非阻塞告警

现有构建仍报告 QRScanner actor 隔离、JSONRPCClient 无效 `await` 和 TerminalSession 未使用绑定等告警；本轮五个修复提交未新增这些告警。
