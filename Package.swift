// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BetaDisplay",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "BetaDisplay", targets: ["BetaDisplay"])
    ],
    targets: [
        .executableTarget(
            name: "BetaDisplay",
            path: "Sources/BetaDisplay",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
