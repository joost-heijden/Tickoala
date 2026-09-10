// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WifiHours",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "WifiHoursCore", targets: ["WifiHoursCore"]),
        .executable(name: "wifihours", targets: ["wifihours"]),
        .executable(name: "WifiHoursApp", targets: ["WifiHoursApp"]),
        .executable(name: "WifiHoursChecks", targets: ["WifiHoursChecks"]),
    ],
    targets: [
        .target(
            name: "WifiHoursCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "wifihours",
            dependencies: ["WifiHoursCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "WifiHoursApp",
            dependencies: ["WifiHoursCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // De testsuite draait als los programma: de Command Line Tools leveren
        // geen XCTest of swift-testing, alleen de volledige Xcode doet dat.
        .executableTarget(
            name: "WifiHoursChecks",
            dependencies: ["WifiHoursCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
