// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "portman",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "portman", targets: ["Portman"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "Portman",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/Portman"
        ),
        .testTarget(
            name: "PortmanTests",
            dependencies: ["Portman"],
            path: "Tests/PortmanTests"
        )
    ]
)
