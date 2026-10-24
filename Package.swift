// swift-tools-version: 6.0
import PackageDescription

// =============================================================================
// 外部パッケージ一覧の正本（表は docs / rules に複製しない → .agents/rules/architecture.md）
//
// | パッケージ                    | 用途                         | リンク先ターゲット                          |
// |-------------------------------|------------------------------|---------------------------------------------|
// | SwiftSoup                     | 壊れた HTML/XBRL 注記パース  | BlueTickerCore, BlueTickerTests             |
// | ZIPFoundation                 | EDINET XBRL ZIP 展開         | BlueTickerCore, BlueTickerTests             |
// | swift-crypto                  | R2 SigV4 HMAC-SHA256         | BlueTickerCore（Vapor 推移的だが Core 直接）|
// | fluent-kit                    | ORM（Vapor なし）            | BltStoreCore, BltIngestCore                 |
// | sql-kit                       | 生 SQL                       | BltStoreCore, BltIngestCore                 |
// | swift-log / swift-nio         | ログ / DB 接続のイベントループ | BltStoreCore, BltIngestCore               |
// | vapor                         | REST トランスポート          | BltServerCore, BltServerCoreTests           |
// | fluent                        | ORM の Vapor 連携            | BltServerCore, BltServerCoreTests           |
// | fluent-postgres-driver        | Neon / Postgres              | BltStoreCore 以上, BltServerCoreTests       |
// | fluent-sqlite-driver          | テスト用インメモリ DB        | BltServerCoreTests のみ                     |
// | swift-sdk (MCP)               | MCP プロトコル               | BltMcpServerCore, BltMcpServerCoreTests     |
//
// ターゲット間（取り込みと配信の分離）:
//   blt-ingest（Mac 専用・書き込み）: BltIngest → BltIngestCore → BltStoreCore → BlueTickerCore
//   blt-server（Fly 専用・読み取り）: BltServer → BltServerCore → BltStoreCore / BltMcpServerCore
// BltStoreCore（Models・格納済みデータの読み取り・DB 接続）と BltIngestCore は Vapor / MCP に依存しない。
// マイグレーション（DDL）は BltIngestCore にだけ置く（blt-server は読み取りロールで動く）。
// Core は Vapor/Fluent を参照しない（AGENTS.md / docs/architecture.md）。
// 検証: smoke/golden の後、使い捨て Neon へ ingest して /v1 契約を確認する。
// =============================================================================

let package = Package(
    name: "BlueTicker",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "blt-ingest", targets: ["BltIngest"]),
        .executable(name: "blt-server", targets: ["BltServer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
        .package(url: "https://github.com/vapor/vapor.git", from: "4.92.0"),
        .package(url: "https://github.com/vapor/fluent.git", from: "4.9.0"),
        .package(url: "https://github.com/vapor/fluent-kit.git", from: "1.52.2"),
        .package(url: "https://github.com/vapor/sql-kit.git", from: "3.33.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.3"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/vapor/fluent-postgres-driver.git", from: "2.8.0"),
        .package(url: "https://github.com/vapor/fluent-sqlite-driver.git", from: "4.6.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.0.0"),
    ],
    targets: [
        .target(
            name: "BlueTickerCore",
            dependencies: [
                "SwiftSoup",
                "ZIPFoundation",
                .product(name: "Crypto", package: "swift-crypto"),
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
        // Models・格納済みデータの読み取り・DB 接続（Vapor なし）。取り込みと配信の両方が使う。
        .target(
            name: "BltStoreCore",
            dependencies: [
                "BlueTickerCore",
                .product(name: "FluentKit", package: "fluent-kit"),
                .product(name: "FluentSQL", package: "fluent-kit"),
                .product(name: "SQLKit", package: "sql-kit"),
                .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
            path: "Sources/BltStoreCore",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        // 取り込み・書き込み・マイグレーション（Vapor / MCP なし。Mac の blt-ingest だけが使う）。
        .target(
            name: "BltIngestCore",
            dependencies: [
                "BlueTickerCore",
                "BltStoreCore",
                .product(name: "FluentKit", package: "fluent-kit"),
                .product(name: "FluentSQL", package: "fluent-kit"),
                .product(name: "SQLKit", package: "sql-kit"),
                .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/BltIngestCore",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        // 配信（REST・MCP）。DB は読み取りのみ。
        .target(
            name: "BltServerCore",
            dependencies: [
                "BlueTickerCore",
                "BltStoreCore",
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
        // エントリのみ。取り込み・書き込みは BltIngestCore 経由。
        .executableTarget(
            name: "BltIngest",
            dependencies: [
                "BltIngestCore",
                "BltStoreCore",
            ],
            path: "Sources/BltIngest",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        // エントリのみ。Web/DB は BltServerCore 経由（BlueTickerCore を直接リンクしない）。
        .executableTarget(
            name: "BltServer",
            dependencies: [
                "BltServerCore",
                "BltStoreCore",
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
        .testTarget(
            name: "BltServerCoreTests",
            dependencies: [
                "BltServerCore",
                "BltStoreCore",
                "BltIngestCore",
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
