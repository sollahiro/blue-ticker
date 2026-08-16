// swift-tools-version: 6.0
import PackageDescription

// =============================================================================
// 外部パッケージ一覧の正本（表は docs / rules に複製しない → .agents/rules/project/dependencies.md）
//
// | パッケージ                    | 用途                         | リンク先ターゲット                          |
// |-------------------------------|------------------------------|---------------------------------------------|
// | swift-argument-parser         | TickerDev CLI                | BlueTickerCore, BlueTickerTests             |
// | SwiftSoup                     | 壊れた HTML/XBRL 注記パース  | BlueTickerCore, BlueTickerTests             |
// | ZIPFoundation                 | EDINET XBRL ZIP 展開         | BlueTickerCore, BlueTickerTests             |
// | swift-crypto                  | R2 SigV4 HMAC-SHA256         | BlueTickerCore（Vapor 推移的だが Core 直接）|
// | vapor                         | REST トランスポート          | BltServerCore, BltServerCoreTests           |
// | fluent                        | ORM                          | BltServerCore, BltServerCoreTests           |
// | fluent-postgres-driver        | Neon / Postgres              | BltServerCore, BltServerCoreTests           |
// | fluent-sqlite-driver          | テスト用インメモリ DB        | BltServerCoreTests のみ                     |
// | swift-sdk (MCP)               | MCP プロトコル               | BltMcpServerCore, BltMcpServerCoreTests     |
//
// ターゲット間: BltServer → BltServerCore → BlueTickerCore / BltMcpServerCore
//               TickerDev → BlueTickerCore
// Core は Vapor/Fluent を参照しない（AGENTS.md / docs/architecture.md）。
// =============================================================================

let package = Package(
    name: "BlueTicker",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "blt-server", targets: ["BltServer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
        .package(url: "https://github.com/vapor/vapor.git", from: "4.92.0"),
        .package(url: "https://github.com/vapor/fluent.git", from: "4.9.0"),
        .package(url: "https://github.com/vapor/fluent-postgres-driver.git", from: "2.8.0"),
        .package(url: "https://github.com/vapor/fluent-sqlite-driver.git", from: "4.6.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.0.0"),
    ],
    targets: [
        .target(
            name: "BlueTickerCore",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "SwiftSoup",
                "ZIPFoundation",
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/BlueTicker",
            exclude: [
                "API/Esef/README.md",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ],
            linkerSettings: [
                // CP932 デコード（decodeCP932）で system iconv を使用。
                // macOS は libiconv の明示リンクが必要。Linux は glibc 内蔵のため不要。
                .linkedLibrary("iconv", .when(platforms: [.macOS])),
            ]
        ),
        .target(
            name: "BltMcpServerCore",
            dependencies: [
                "BlueTickerCore",
                .product(name: "MCP", package: "swift-sdk"),
            ],
            path: "Sources/BltMcpServerCore",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "BltServerCore",
            dependencies: [
                "BlueTickerCore",
                "BltMcpServerCore",
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
            ],
            path: "Sources/BltServerCore",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        // エントリのみ。Web/DB は BltServerCore 経由（BlueTickerCore を直接リンクしない）。
        .executableTarget(
            name: "BltServer",
            dependencies: [
                "BltServerCore",
            ],
            path: "Sources/BltServer",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        // 開発用ローカル解析 CLI（配布しない）。products に含めない。
        .executableTarget(
            name: "TickerDev",
            dependencies: [
                "BlueTickerCore",
            ],
            path: "Sources/TickerDevMain",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "BlueTickerTests",
            dependencies: [
                "BlueTickerCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "ZIPFoundation",
                "SwiftSoup",
            ],
            path: "SwiftTests/BlueTickerTests"
        ),
        .testTarget(
            name: "BltServerCoreTests",
            dependencies: [
                "BltServerCore",
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
                .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver"),
                .product(name: "Vapor", package: "vapor"),
            ],
            path: "SwiftTests/BltServerCoreTests"
        ),
        .testTarget(
            name: "BltMcpServerCoreTests",
            dependencies: [
                "BltMcpServerCore",
                .product(name: "MCP", package: "swift-sdk"),
            ],
            path: "SwiftTests/BltMcpServerCoreTests"
        ),
    ]
)
