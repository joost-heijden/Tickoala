// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tickoala",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "TickoalaCore", targets: ["TickoalaCore"]),
        .executable(name: "tickoala", targets: ["tickoala"]),
        .executable(name: "TickoalaApp", targets: ["TickoalaApp"]),
        .executable(name: "TickoalaChecks", targets: ["TickoalaChecks"]),
    ],
    targets: [
        .target(
            name: "TickoalaCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "tickoala",
            dependencies: ["TickoalaCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "TickoalaApp",
            dependencies: ["TickoalaCore"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The test suite runs as a standalone program: the Command Line Tools
        // ship no XCTest or swift-testing, only full Xcode does.
        .executableTarget(
            name: "TickoalaChecks",
            dependencies: ["TickoalaCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
