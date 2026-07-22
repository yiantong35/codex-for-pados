// swift-tools-version:6.0
import PackageDescription
let package = Package(
    name: "relay-server",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(path: "../packages/RelayProtocol"),
    ],
    targets: [
        .target(name: "RelayServerCore", dependencies: [
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "NIOWebSocket", package: "swift-nio"),
            "RelayProtocol",
        ]),
        .executableTarget(name: "relay-server", dependencies: ["RelayServerCore"]),
        .testTarget(name: "RelayServerCoreTests", dependencies: ["RelayServerCore"]),
    ]
)
