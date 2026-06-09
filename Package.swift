// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BlueTicker",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "ticker", targets: ["BlueTicker"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
    ],
    targets: [
        .executableTarget(
            name: "BlueTicker",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "SwiftSoup",
                "ZIPFoundation",
            ],
            path: "Sources/BlueTicker",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "BlueTickerTests",
            dependencies: ["BlueTicker"],
            path: "Tests/BlueTickerTests"
        ),
    ]
)
