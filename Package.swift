// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TunnelBar",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "TunnelBar", targets: ["TunnelBar"]),
        .library(name: "TunnelBarCore", targets: ["TunnelBarCore"])
    ],
    targets: [
        .executableTarget(
            name: "TunnelBar",
            dependencies: ["TunnelBarCore"]
        ),
        .target(
            name: "TunnelBarCore"
        ),
        .testTarget(
            name: "TunnelBarCoreTests",
            dependencies: ["TunnelBarCore"]
        )
    ]
)
