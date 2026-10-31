// swift-tools-version: 6.0
import PackageDescription

/// iOS アプリ本体は Xcode プロジェクト。このパッケージはチャットに渡す数字（前期比・利益率差）と
/// 生成モデルへの文脈の組み立てを Linux / macOS で `swift test` するための切り出し。
let package = Package(
    name: "ChatFacts",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "ChatFacts", targets: ["ChatFacts"]),
    ],
    targets: [
        .target(
            name: "ChatFacts",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "ChatFactsTests",
            dependencies: ["ChatFacts"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
