// swift-tools-version: 6.0
import PackageDescription

/// iOS アプリ本体は Xcode プロジェクト。このパッケージは ROE/ROIC の 0 軸塗り分割を
/// Linux / macOS で `swift test` するための切り出し。
let package = Package(
    name: "ZeroAxisFill",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "ZeroAxisFill", targets: ["ZeroAxisFill"]),
    ],
    targets: [
        .target(
            name: "ZeroAxisFill",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "ZeroAxisFillTests",
            dependencies: ["ZeroAxisFill"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
