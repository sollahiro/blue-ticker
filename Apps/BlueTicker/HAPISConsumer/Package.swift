// swift-tools-version: 6.0
import PackageDescription

/// iOS アプリ本体は Xcode プロジェクト。このパッケージは HAPIS consumer の
/// Foundation 層を Linux / macOS で `swift test` するための切り出し。
let package = Package(
    name: "HAPISConsumer",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "HAPISConsumer", targets: ["HAPISConsumer"]),
    ],
    targets: [
        .target(
            name: "HAPISConsumer",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "HAPISConsumerTests",
            dependencies: ["HAPISConsumer"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
