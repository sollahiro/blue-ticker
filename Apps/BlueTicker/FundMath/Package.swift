// swift-tools-version: 6.0
import PackageDescription

/// iOS アプリ本体は Xcode プロジェクト。このパッケージはマイファンドのルックスルー計算を
/// Linux / macOS で `swift test` するための切り出し。
let package = Package(
    name: "FundMath",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "FundMath", targets: ["FundMath"]),
    ],
    targets: [
        .target(
            name: "FundMath",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "FundMathTests",
            dependencies: ["FundMath"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
