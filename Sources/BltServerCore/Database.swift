// Fluent（DB 層）の配線。
// DATABASE_URL（Neon の Postgres 接続文字列）が設定されているときのみ Postgres を登録し、
// Stage 1 のマイグレーションを適用する。
// 未設定なら DB なしで起動する（現行のステートレス EDINET プロキシ動作を維持）。

import Fluent
import FluentPostgresDriver
import Vapor

/// DATABASE_URL があれば Postgres を `.psql` として登録し、未適用のマイグレーションを実行する。
/// TLS / sslmode は接続 URL のクエリ（例: `?sslmode=require`）から解決される（Neon は TLS 必須）。
func configureDatabase(_ app: Application) async throws {
    guard let urlString = Environment.get("DATABASE_URL"), !urlString.isEmpty else {
        app.logger.notice("DATABASE_URL 未設定。DB なしで起動します（ステートレス EDINET プロキシ）。")
        return
    }

    let configuration = try SQLPostgresConfiguration(url: urlString)
    app.databases.use(.postgres(configuration: configuration), as: .psql)

    // Stage 1: 書類一覧（edinet_documents）と同期進捗（edinet_sync_state）。
    app.migrations.add(CreateEdinetDocument())
    app.migrations.add(CreateEdinetSyncState())
    // Stage 3: XBRL 数値 RAW（edinet_xbrl_facts、書類単位 JSONB）。
    app.migrations.add(CreateEdinetXbrlFacts())
    // Stage 4: 計算済み財務サマリ（company_financials、企業単位 JSONB）。
    app.migrations.add(CreateCompanyFinancials())
    // Stage 4-half: 計算済み半期財務サマリ（company_half_financials、企業単位 JSONB）。
    app.migrations.add(CreateCompanyHalfFinancials())
    // Stage 5: 有報セクション本文（company_filing_sections、書類単位 JSONB）。
    app.migrations.add(CreateCompanyFilingSections())
    try await app.autoMigrate()

    app.logger.notice("Postgres (Neon) を登録し、マイグレーションを適用しました。")
}
