// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BlueTicker",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "ticker", targets: ["BlueTicker"]),
        .executable(name: "blt-server", targets: ["BltServer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        // 共有ライブラリ（CLI・MCPサーバー共通のコア機能）
        .target(
            name: "BlueTickerCore",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "SwiftSoup",
                "ZIPFoundation",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/BlueTicker",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        // CLI 実行可能ターゲット（@main エントリポイントのみ）
        .executableTarget(
            name: "BlueTicker",
            dependencies: [
                "BlueTickerCore",
            ],
            path: "Sources/BlueTickerMain",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        // MCP サーバー実行可能ターゲット
        .executableTarget(
            name: "BltServer",
            dependencies: [
                "BlueTickerCore",
            ],
            path: "Sources/BltServer",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "BlueTickerTests",
            dependencies: [
                "BlueTickerCore",
                "ZIPFoundation",
                "SwiftSoup",
            ],
            path: "SwiftTests/BlueTickerTests"
        ),
    ]
)
