// Vapor を使わない DB 接続（blt-ingest のコマンドと、blt-server の read 専用コマンドが使う）。
// 配信サーバー本体は Vapor の `app.databases` に同じ設定で登録する（BltServerCore/Database.swift）。
//
// DATABASE_URL（Neon の Postgres 接続文字列）から `.psql` を登録する。TLS / sslmode は接続 URL の
// クエリ（例: `?sslmode=require`）から解決される（Neon は TLS 必須）。マイグレーションはここでは
// 適用しない（BltIngestCore の `migrateBltSchema` だけが DDL を出す）。

import BlueTickerCore
import FluentKit
import FluentPostgresDriver
import Foundation
import Logging
import NIOCore
import NIOPosix

/// プロセス環境変数を読む（Vapor の `Environment.get` の代わり）。空文字は未設定として扱う。
package func bltEnvironmentValue(_ key: String) -> String? {
    guard let value = ProcessInfo.processInfo.environment[key], !value.isEmpty else { return nil }
    return value
}

/// DATABASE_URL から Postgres を登録した `Databases`。コマンド 1 回分の寿命で使い、最後に `asyncShutdown` する。
package final class BltCommandDatabase: @unchecked Sendable {
    package let databases: Databases
    package let logger: Logger
    private let eventLoopGroup: any EventLoopGroup

    /// 呼び出しごとに新しい `Database`（イベントループは任意）を返す。Vapor の `app.db` と同じ使い方をする。
    package var db: any Database {
        databases.database(logger: logger, on: eventLoopGroup.any())!
    }

    private init(databases: Databases, logger: Logger, eventLoopGroup: any EventLoopGroup) {
        self.databases = databases
        self.logger = logger
        self.eventLoopGroup = eventLoopGroup
    }

    /// DATABASE_URL を読み、未設定なら nil。
    package static func connectFromEnvironment(label: String) throws -> BltCommandDatabase? {
        guard let urlString = bltEnvironmentValue("DATABASE_URL") else { return nil }
        return try connect(urlString: urlString, label: label)
    }

    package static func connect(urlString: String, label: String) throws -> BltCommandDatabase {
        let logger = Logger(label: label)
        // sslmode の明示がない接続文字列は警告を出す（Neon は TLS 必須のため実害は小さいが、
        // 設定ミスの早期検出のため。`disable` 指定は意図的な場合のみ許容する）。
        if !urlString.contains("sslmode=") {
            logger.warning(
                "DATABASE_URL に sslmode の指定がありません。本番接続は `?sslmode=require` を明示してください。")
        }
        let eventLoopGroup = MultiThreadedEventLoopGroup.singleton
        let databases = Databases(threadPool: NIOThreadPool.singleton, on: eventLoopGroup)
        databases.use(try bltPostgresConfiguration(urlString: urlString), as: .psql)
        logger.notice(
            "Postgres 接続プール設定: maxConnectionsPerEventLoop=\(Api.dbMaxConnectionsPerEventLoop) connectionPoolTimeout=\(Api.dbConnectionPoolTimeoutSeconds)s"
        )
        return BltCommandDatabase(databases: databases, logger: logger, eventLoopGroup: eventLoopGroup)
    }

    package func asyncShutdown() async {
        await databases.shutdownAsync()
    }
}

/// 本番の接続プール設定（サーバーとコマンドで共通）。
package func bltPostgresConfiguration(urlString: String) throws -> DatabaseConfigurationFactory {
    .postgres(
        configuration: try SQLPostgresConfiguration(url: urlString),
        maxConnectionsPerEventLoop: Api.dbMaxConnectionsPerEventLoop,
        connectionPoolTimeout: .seconds(Api.dbConnectionPoolTimeoutSeconds)
    )
}
