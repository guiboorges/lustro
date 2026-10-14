// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Lustro",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Lustro", targets: ["Lustro"]),
        .library(name: "LustroCore", targets: ["LustroCore"]),
    ],
    targets: [
        .target(
            name: "LustroCore",
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "Lustro",
            dependencies: ["LustroCore"]
        ),
        .testTarget(
            name: "LustroCoreTests",
            dependencies: ["LustroCore"]
        ),
    ]
)
