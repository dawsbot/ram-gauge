// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RAMGauge",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "RAMGaugeCore", targets: ["RAMGaugeCore"]),
        .executable(name: "RAMGauge", targets: ["RAMGauge"])
    ],
    targets: [
        .target(name: "RAMGaugeCore"),
        .executableTarget(name: "RAMGauge", dependencies: ["RAMGaugeCore"]),
        .testTarget(name: "RAMGaugeCoreTests", dependencies: ["RAMGaugeCore"])
    ]
)
