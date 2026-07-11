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
        // REST サーバー（HTTP・ルーティング・ミドルウェア）と DB 層（Fluent ORM ＋ Neon 接続）。
        // BltServerCore ターゲットのみが使用。素 NIO は Vapor が内包するため個別依存は持たない。
        .package(url: "https://github.com/vapor/vapor.git", from: "4.92.0"),
        .package(url: "https://github.com/vapor/fluent.git", from: "4.9.0"),
        .package(url: "https://github.com/vapor/fluent-postgres-driver.git", from: "2.8.0"),
        // テスト専用: マイグレーションをインメモリ DB で実走させ検証する（本番は Postgres）。
        .package(url: "https://github.com/vapor/fluent-sqlite-driver.git", from: "4.6.0"),
        // MCP プロトコル実装（公式 SDK）。BltMcpServerCore ターゲットのみが使用。
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1"),
    ],
    targets: [
        // 共有ライブラリ（CLI・REST サーバー共通のコア機能）。NIO には依存しない。
        .target(
            name: "BlueTickerCore",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "SwiftSoup",
                "ZIPFoundation",
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
        // MCP プロトコル層。ツールカタログと MCP.Server ファクトリのみを持つ。
        // Vapor/Fluent には依存しない（BltServerCore が /mcp ルートとして埋め込む）。
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
        // REST サーバーのトランスポート層（Vapor）と DB 層（Fluent）。
        // Web/DB 依存をここに閉じ込め、CLI へ漏らさない。
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
                "BltServerCore",
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
        // BltServerCore（DB 層）のテスト。マイグレーションをインメモリ SQLite で実走検証する。
        .testTarget(
            name: "BltServerCoreTests",
            dependencies: [
                "BltServerCore",
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver"),
                .product(name: "Vapor", package: "vapor"),
            ],
            path: "SwiftTests/BltServerCoreTests"
        ),
        // BltMcpServerCore（MCP プロトコル層）のテスト。
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
