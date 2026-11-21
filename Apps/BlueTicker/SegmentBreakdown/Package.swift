// swift-tools-version: 6.0
import PackageDescription

/// iOS アプリ本体は Xcode プロジェクト。このパッケージはセグメント・地域カードの
/// 積み上げ棒の配置とつなぎ（connect / 再編 / 新規 / 終了）を Linux / macOS で `swift test` するための切り出し。
let package = Package(
    name: "SegmentBreakdown",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "SegmentBreakdown", targets: ["SegmentBreakdown"]),
    ],
    targets: [
        .target(
            name: "SegmentBreakdown",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "SegmentBreakdownTests",
            dependencies: ["SegmentBreakdown"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
