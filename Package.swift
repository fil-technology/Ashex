// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "Ashex",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "AshexCore",
            targets: ["AshexCore"]
        ),
        .executable(
            name: "ashex",
            targets: ["AshexCLI"]
        ),
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite"
        ),
        .target(
            name: "AshexCore",
            dependencies: ["CSQLite"]
        ),
        .executableTarget(
            name: "AshexCLI",
            dependencies: ["AshexCore"]
        ),
        .testTarget(
            name: "AshexCoreTests",
            dependencies: ["AshexCore"]
        ),
        .testTarget(
            name: "AshexCLITests",
            dependencies: ["AshexCLI", "AshexCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
