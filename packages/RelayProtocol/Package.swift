// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "RelayProtocol",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [
        .library(name: "RelayProtocol", targets: ["RelayProtocol"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")
    ],
    targets: [
        .target(
            name: "RelayProtocol",
            dependencies: [.product(name: "Crypto", package: "swift-crypto")]
        ),
        .testTarget(
            name: "RelayProtocolTests",
            dependencies: ["RelayProtocol"]
        )
    ]
)
