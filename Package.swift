// swift-tools-version: 6.0
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
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    ],
    targets: [
        // 共有ライブラリ（CLI・REST サーバー共通のコア機能）
        .target(
            name: "BlueTickerCore",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "SwiftSoup",
                "ZIPFoundation",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            path: "Sources/BlueTicker",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ],
            linkerSettings: [
                // CP932 デコード（decodeCP932）で system iconv を使用。
                // macOS は libiconv の明示リンクが必要。Linux は glibc 内蔵のため不要。
                .linkedLibrary("iconv", .when(platforms: [.macOS])),
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
                .swiftLanguageMode(.v6),
            ]
        ),
        // REST サーバー実行可能ターゲット
        .executableTarget(
            name: "BltServer",
            dependencies: [
                "BlueTickerCore",
            ],
            path: "Sources/BltServer",
            swiftSettings: [
                .swiftLanguageMode(.v6),
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
