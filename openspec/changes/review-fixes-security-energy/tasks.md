# Tasks: review-fixes-security-energy

> 8 处缺陷 = 8 组任务，无相互依赖，可独立提交/回滚。每组完成后 tasks.md 打勾 + git commit（不积攒，comet build 铁律）。

## 1. #1 终端 OSC52 剪贴板写门控（安全）

- [x] 1.1 新增默认关闭的「允许远端写剪贴板」设置项（复用既有设置页容器）
- [x] 1.2 `SwiftTermView.clipboardCopy` 改为读该开关：关则丢弃；开则限单次字节上限后写 `UIPasteboard`
- [x] 1.3 单测：开关关时远端 OSC52 不改剪贴板；开且超限时拒写；`clipboardRead` 仍返回 nil

## 2. #2 dev 侧信任落盘后再发布会话（安全）

- [x] 2.1 `DialoutContext.handleClientAuth`：`trust.trust` 成功后才在锁内原子置 `_session` + `_pairingConsumed`
- [x] 2.2 落盘失败清握手态并向上抛；`main.swift` 调用方去掉 `try?`，失败不启 bridge
- [x] 2.3 单测：落盘失败时 session 不发布、后续 SecureEnvelope 不启 bridge；受信任复连幂等路径不回归

## 3. #5 iPad 身份密钥落盘成功后才缓存（安全）

- [x] 3.1 `KeyStoring.saveKey` 签名改 `throws`，生产 Keychain 实现真实抛错（搜清全部调用点）
- [x] 3.2 `RelayE2EKeyManager.identityKey()` 仅保存成功后缓存返回；覆盖旧项用 upsert 避免先删后加丢身份
- [x] 3.3 单测：saveKey 失败时不缓存、配对失败而非静默成功

## 4. #8 dev 加载已有私钥校验权限（安全）

- [ ] 4.1 `DevKeyStore.loadOrCreateIdentity` 读已存在文件前拒绝符号链接、校验属主、收紧 0600、目录 0700
- [ ] 4.2 修复失败则 throw 拒绝启动
- [ ] 4.3 单测：0644/属主不符/符号链接三种场景均 fail-closed

## 5. #3 空闲会话按需调度攒批（能耗）

- [ ] 5.1 去掉 `startCoalesceTimer` 常驻 `while` 循环，改为脏 delta 触发的一次性延迟 flush
- [ ] 5.2 `flushCoalesced` drain 后不续期，下批脏数据重新调度；`stopObserving` 仍兜底 flush
- [ ] 5.3 单测：无 delta 时无周期唤醒；连续 delta 仍按 ~30Hz 攒批；尾字不丢

## 6. #4 扫码相机启停串行化（能耗/隐私）

- [ ] 6.1 `QRScannerView.PreviewView` 引入私有串行 capture 队列 + `desiredRunning` 目标态
- [ ] 6.2 `start`/`stop` 只设目标态并在串行队列排「对齐」任务，`stop` 无条件排队不早退
- [ ] 6.3 验证：dismantle 后相机不残留运行（状态机单测 + 真机抽验）

## 7. #6 侧栏首拉后按可见性再轮询（能耗）

- [ ] 7.1 `SidebarView.task` 在 `startPolling` 前 `guard !Task.isCancelled && scenePhase == .active`
- [ ] 7.2 `ProjectsStore.startPolling` 加可见性前置
- [ ] 7.3 单测/断言：后台或视图消失时首拉返回不重启轮询

## 8. #7 后台暂停在途首连（能耗）

- [ ] 8.1 `ConnectionStore.setForeground` 同步状态给 `inFlightTransport`（不止已落地 transport）
- [ ] 8.2 `doEstablish` 建通道与初始握手前检查/等待前台；退后台进行中首连走 attempt-token 作废 + take-and-nil 取消，回前台重试
- [ ] 8.3 单测：首连期间退后台不继续握手/加密；回前台重试成功；不泄漏 transport

## 9. 收口验证

- [ ] 9.1 四个 Swift Package 测试全绿
- [ ] 9.2 iPad 模拟器全量测试全绿
- [ ] 9.3 `xcodebuild analyze` 通过
- [ ] 9.4 能耗结论静态分析归纳，真机验收项写入本地清单
