// swift-tools-version: 6.0
import PackageDescription

/// iOS アプリ本体は Xcode プロジェクト。このパッケージは条件検索のスナップショット
/// （`GET /v1/screen/snapshot`）の解析・端末内検索・条件付き GET の判定を Linux / macOS で
/// `swift test` するための切り出し。
let package = Package(
    name: "ScreenSnapshot",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "ScreenSnapshot", targets: ["ScreenSnapshot"]),
    ],
    targets: [
        .target(
            name: "ScreenSnapshot",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "ScreenSnapshotTests",
            dependencies: ["ScreenSnapshot"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
