// swift-tools-version:5.9
import PackageDescription

// mac-daemon: Codex 广播 daemon。
// DaemonCore: 纯逻辑 + actor + NIO WSServer。
// codex-bridge-daemon: 可执行 target,组装并启动 daemon。
let package = Package(
    name: "mac-daemon",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "DaemonCore", targets: ["DaemonCore"]),
        .executable(name: "codex-bridge-daemon", targets: ["codex-bridge-daemon"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0")
    ],
    targets: [
        .target(
            name: "DaemonCore",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio")
            ]
        ),
        .executableTarget(
            name: "codex-bridge-daemon",
            dependencies: ["DaemonCore"]
        ),
        .testTarget(
            name: "DaemonCoreTests",
            dependencies: ["DaemonCore"]
        )
    ]
)
