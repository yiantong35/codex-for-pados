# CodexRemote 开发环境说明（Dev Setup）

iPad 上的 Codex 远程客户端。通过 SSH 连接同一局域网内 Mac 上运行的 Codex app-server，
在 iPad 上进行会话操作。本文件说明本地开发与构建环境。

## 工程结构

```
ios/
  project.yml                 # xcodegen 工程描述（事实源，不手改 .xcodeproj）
  CodexRemote.xcodeproj       # 由 xcodegen 生成，不纳入手工编辑
  CodexRemote/
    App/        # CodexRemoteApp.swift、根视图
    Transport/  # SSHClient、ProxyChannel（Citadel）
    RPC/        # JSONRPCClient、信封类型
    Protocol/   # 生成的 Codable 协议类型 + 手写补充
    Domain/     # ThreadReducer、领域模型
    Stores/     # @Observable Stores
    Views/      # SwiftUI 视图
    Security/   # KeychainStore
    Info.plist  # 含 NSLocalNetworkUsageDescription
  CodexRemoteTests/           # XCTest 单元测试 target
```

工程用 **xcodegen** 从 `ios/project.yml` 生成，**不要**用 Xcode 图形界面改工程结构。
改了 `project.yml` 后执行：

```bash
cd ios && xcodegen generate
```

## 部署目标与工具链

- **最低部署目标：iPadOS 17.0**（支持 Observation / `@Observable` 框架）
- **Swift 版本：6.0**（本机 Swift 6.3.2 工具链）
- **Xcode：26.5**（构建用 SDK iOS 26.5）
- **设备族：仅 iPad**（`TARGETED_DEVICE_FAMILY = 2`）
- **Bundle ID：`com.example.codexremote`**（占位，侧载开发用；真机签名时替换为你的开发者前缀）

> 注意：本机仅安装了 iOS 26.5 模拟器 runtime。部署目标声明为 17.0（向下兼容目标），
> 但**模拟器构建/测试只能在 iOS 26.5 runtime 上进行**。若要验证 17.x 兼容性需另装对应 runtime 或用真机。

## 依赖

- **Citadel `0.12.1`**（`https://github.com/orlandos-nl/Citadel`）—— 纯 Swift SSH 客户端，
  用于 Transport 层与 Mac 建立 SSH 连接并做端口转发到 Codex app-server。
  在 `project.yml` 的 `packages` 段声明，加入 `CodexRemote` target。
  目前空壳尚未 `import Citadel`，实际接线在 Task 3（Transport spike）。

## 构建与测试

创建 iPad 模拟器（一次性）：

```bash
xcrun simctl create "iPad-Test" \
  "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11-inch-M4-8GB" \
  "com.apple.CoreSimulator.SimRuntime.iOS-26-5"
```

构建：

```bash
cd ios && xcodegen generate
xcodebuild -project ios/CodexRemote.xcodeproj -scheme CodexRemote \
  -destination 'platform=iOS Simulator,name=iPad-Test' \
  -derivedDataPath ios/DerivedData build
```

测试：

```bash
xcodebuild -project ios/CodexRemote.xcodeproj -scheme CodexRemote \
  -destination 'platform=iOS Simulator,name=iPad-Test' \
  -derivedDataPath ios/DerivedData test
```

## 模拟器 vs 真机

- **模拟器**：用于纯 UI / 逻辑开发与单测。注意模拟器与真机网络栈差异——本地网络权限
  （`NSLocalNetworkUsageDescription`）在真机上会弹授权对话框，模拟器通常不弹。
  连接真实 Mac SSH 时建议用真机或确保模拟器与 Mac 在同一可达网络。
- **真机（侧载）**：需配置 `DEVELOPMENT_TEAM` 与有效签名身份，替换占位 Bundle ID。
  本地网络权限对话框首次连接时弹出，用户需允许后方可发现并连接局域网内 Mac。

## 配合 Mac 端启动脚本

iPad 客户端连接的目标是 Mac 上运行的 Codex app-server。Mac 端的启动 / 端口暴露脚本
由 **Task 2** 产出（届时在仓库 `scripts/` 下，本节将补充指向其路径与用法）。
开发期间需先在 Mac 上把 Codex app-server 跑起来，并确保 SSH 可达。
