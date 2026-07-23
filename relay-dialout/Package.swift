// swift-tools-version:6.0
import PackageDescription
let package = Package(
    name: "relay-dialout",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.25.0"),
        .package(path: "../packages/RelayProtocol"),
    ],
    targets: [
        .target(name: "RelayDialoutCore", dependencies: [
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "NIOWebSocket", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
            "RelayProtocol",
        ]),
        .executableTarget(name: "relay-dialout", dependencies: ["RelayDialoutCore"]),
        .testTarget(name: "RelayDialoutCoreTests", dependencies: ["RelayDialoutCore"]),
    ]
)
