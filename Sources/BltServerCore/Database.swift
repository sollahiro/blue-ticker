// 配信サーバーの Fluent（DB 層）の配線。
// DATABASE_URL（Neon の Postgres 接続文字列）が設定されているときのみ Postgres を登録する。
// 未設定なら DB なしで起動する（現行のステートレス EDINET プロキシ動作を維持）。
//
// マイグレーション（DDL）は登録も適用もしない。DDL は blt-ingest（Mac の書き込み側）だけが出し、
// 配信サーバーは読み取りロール（blt_reader）で動く（docs/ingest-policy.md「出荷順」）。

import BltStoreCore
import BlueTickerCore
import Fluent
import Vapor

/// DATABASE_URL があれば Postgres を `.psql` として登録する（接続プール設定は blt-ingest と共通）。
func configureServerDatabase(_ app: Application) throws {
    guard let urlString = Environment.get("DATABASE_URL"), !urlString.isEmpty else {
        app.logger.notice("DATABASE_URL 未設定。DB なしで起動します（ステートレス EDINET プロキシ）。")
        return
    }

    // sslmode の明示がない接続文字列は警告を出す（Neon は TLS 必須のため実害は小さいが、
    // 設定ミスの早期検出のため。`disable` 指定は意図的な場合のみ許容する）。
    if !urlString.contains("sslmode=") {
        app.logger.warning(
            "DATABASE_URL に sslmode の指定がありません。本番接続は `?sslmode=require` を明示してください。")
    }

    app.databases.use(try bltPostgresConfiguration(urlString: urlString), as: .psql)
    app.logger.notice(
        "Postgres (Neon) を登録しました（読み取りのみ。maxConnectionsPerEventLoop=\(Api.dbMaxConnectionsPerEventLoop) connectionPoolTimeout=\(Api.dbConnectionPoolTimeoutSeconds)s）。"
    )
}

/// Vapor の `--log` / `LOG_LEVEL` 検出で JSON 1 行ログを有効化する。
func bootstrapBltLogging(from environment: inout Environment) throws {
    bootstrapBltLogging(level: try Logger.Level.detect(from: &environment))
}
