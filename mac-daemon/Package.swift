// swift-tools-version:5.9
import PackageDescription

// mac-daemon: Codex 广播 daemon。
// Task 1 仅声明纯逻辑 DaemonCore library + 测试 target;
// SwiftNIO 等网络依赖在 Task 5 (WSServer) 再加入。
let package = Package(
    name: "mac-daemon",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "DaemonCore", targets: ["DaemonCore"])
    ],
    targets: [
        .target(
            name: "DaemonCore"
        ),
        .testTarget(
            name: "DaemonCoreTests",
            dependencies: ["DaemonCore"]
        )
    ]
)
