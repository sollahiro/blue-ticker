// Fluent（DB 層）の配線。
// DATABASE_URL（Neon の Postgres 接続文字列）が設定されているときのみ Postgres を登録する。
// 未設定なら DB なしで起動する（現行のステートレス EDINET プロキシ動作を維持）。
//
// モデル（Stage 1/3）・マイグレーションは別タスク（スキーマ設計）で追加する。
// ここでは接続の有無のみを扱い、空のマイグレーションは置かない。

import Fluent
import FluentPostgresDriver
import Vapor

/// DATABASE_URL があれば Postgres を `.psql` として登録する。
/// TLS / sslmode は接続 URL のクエリ（例: `?sslmode=require`）から解決される（Neon は TLS 必須）。
func configureDatabase(_ app: Application) throws {
    guard let urlString = Environment.get("DATABASE_URL"), !urlString.isEmpty else {
        app.logger.notice("DATABASE_URL 未設定。DB なしで起動します（ステートレス EDINET プロキシ）。")
        return
    }

    let configuration = try SQLPostgresConfiguration(url: urlString)
    app.databases.use(.postgres(configuration: configuration), as: .psql)
    app.logger.notice("Postgres (Neon) を登録しました。")
}
