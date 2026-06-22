// swift-tools-version:5.9
import PackageDescription

// mac-daemon: Codex 广播 daemon。
// Task 5 (WSServer) 引入 SwiftNIO 用于局域网 WebSocket server。
let package = Package(
    name: "mac-daemon",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "DaemonCore", targets: ["DaemonCore"])
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
        .testTarget(
            name: "DaemonCoreTests",
            dependencies: ["DaemonCore"]
        )
    ]
)
