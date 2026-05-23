// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PortManager",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "PortManager", targets: ["PortManager"])
    ],
    targets: [
        .executableTarget(
            name: "PortManager",
            path: "Sources/PortManager"
        )
    ]
)
