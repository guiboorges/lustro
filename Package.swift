// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Limpo",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Limpo", targets: ["Limpo"]),
        .library(name: "LimpoCore", targets: ["LimpoCore"]),
    ],
    targets: [
        .target(
            name: "LimpoCore",
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "Limpo",
            dependencies: ["LimpoCore"]
        ),
        .testTarget(
            name: "LimpoCoreTests",
            dependencies: ["LimpoCore"]
        ),
    ]
)
