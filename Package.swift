// swift-tools-version: 6.2
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
        .library(
            name: "AshexComputerUse",
            targets: ["AshexComputerUse"]
        ),
        .executable(
            name: "ashex",
            targets: ["AshexCLI"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "603.0.0"),
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite"
        ),
        .target(
            name: "AshexCore",
            dependencies: [
                "CSQLite",
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
            ],
            resources: [
                .process("Resources"),
            ]
        ),
        .target(
            name: "AshexComputerUse",
            dependencies: ["AshexCore"]
        ),
        .executableTarget(
            name: "AshexCLI",
            dependencies: ["AshexCore", "AshexComputerUse"]
        ),
        .testTarget(
            name: "AshexCoreTests",
            dependencies: ["AshexCore"]
        ),
        .testTarget(
            name: "AshexComputerUseTests",
            dependencies: ["AshexComputerUse", "AshexCore"]
        ),
        .testTarget(
            name: "AshexCLITests",
            dependencies: ["AshexCLI", "AshexCore", "AshexComputerUse"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
