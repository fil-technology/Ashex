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
