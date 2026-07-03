// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TunnelBar",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "TunnelBar", targets: ["TunnelBar"]),
        .executable(name: "routingflare", targets: ["RoutingFlareCLI"]),
        .library(name: "TunnelBarCore", targets: ["TunnelBarCore"])
    ],
    targets: [
        .executableTarget(
            name: "TunnelBar",
            dependencies: ["TunnelBarCore"]
        ),
        .executableTarget(
            name: "RoutingFlareCLI",
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
