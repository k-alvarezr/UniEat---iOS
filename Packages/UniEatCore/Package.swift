// swift-tools-version: 6.0
import PackageDescription

// modelos y reglas de unieat, se prueban sin la app ni el simulador
let package = Package(
    name: "UniEatCore",
    platforms: [.iOS(.v17), .macOS(.v12)],
    products: [
        .library(name: "UniEatCore", targets: ["UniEatCore"]),
    ],
    targets: [
        .target(name: "UniEatCore"),
        .testTarget(name: "UniEatCoreTests", dependencies: ["UniEatCore"]),
    ]
)
