// swift-tools-version: 6.0
import PackageDescription

/// iOS アプリ本体は Xcode プロジェクト。このパッケージは Top feed の公開 RSS の解析と
/// 条件付き GET の判定を Linux / macOS で `swift test` するための切り出し。
let package = Package(
    name: "FeedRSS",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "FeedRSS", targets: ["FeedRSS"]),
    ],
    targets: [
        .target(
            name: "FeedRSS",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "FeedRSSTests",
            dependencies: ["FeedRSS"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
