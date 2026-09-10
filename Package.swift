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
        // De testsuite draait als los programma: de Command Line Tools leveren
        // geen XCTest of swift-testing, alleen de volledige Xcode doet dat.
        .executableTarget(
            name: "TickoalaChecks",
            dependencies: ["TickoalaCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
