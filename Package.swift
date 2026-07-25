// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PortManager",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "PortManager", targets: ["PortManager"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "PortManager",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/PortManager"
        ),
        .testTarget(
            name: "PortManagerTests",
            dependencies: ["PortManager"],
            path: "Tests/PortManagerTests"
        )
    ]
)
