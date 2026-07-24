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
    targets: [
        .executableTarget(
            name: "PortManager",
            path: "Sources/PortManager"
        ),
        .testTarget(
            name: "PortManagerTests",
            dependencies: ["PortManager"],
            path: "Tests/PortManagerTests"
        )
    ]
)
