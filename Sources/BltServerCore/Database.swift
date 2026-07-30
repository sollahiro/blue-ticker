// Fluent（DB 層）の配線。
// DATABASE_URL（Neon の Postgres 接続文字列）が設定されているときのみ Postgres を登録し、
// Stage 1 のマイグレーションを適用する。
// 未設定なら DB なしで起動する（現行のステートレス EDINET プロキシ動作を維持）。
//
// `autoMigrate` は withDbRetry で包む。ingest 本体の DB 操作は既にリトライ済みだが、
// プロセス起動直後の初回接続（Neon cold start）はここが唯一の接点で、失敗すると
// sync/ingest 全体が connectionRequestTimeout で即死するため。

import BlueTickerCore
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
    app.databases.use(
        .postgres(
            configuration: configuration,
            maxConnectionsPerEventLoop: Api.dbMaxConnectionsPerEventLoop,
            connectionPoolTimeout: .seconds(Api.dbConnectionPoolTimeoutSeconds)
        ), as: .psql)
    app.logger.notice(
        "Postgres 接続プール設定: maxConnectionsPerEventLoop=\(Api.dbMaxConnectionsPerEventLoop) connectionPoolTimeout=\(Api.dbConnectionPoolTimeoutSeconds)s"
    )

    // Stage 1: 書類一覧（edinet_documents）と同期進捗（edinet_sync_state）。
    app.migrations.add(CreateEdinetDocument())
    app.migrations.add(CreateEdinetSyncState())
    // Stage 3: XBRL 数値 RAW（edinet_xbrl_facts、書類単位 JSONB）。
    app.migrations.add(CreateEdinetXbrlFacts())
    // Stage 4: 計算済み財務サマリ（company_financials、企業単位 JSONB）。
    app.migrations.add(CreateCompanyFinancials())
    // Stage 4-half: 計算済み半期財務サマリ（company_half_financials、企業単位 JSONB）。
    app.migrations.add(CreateCompanyHalfFinancials())
    // Stage 4 / 4-half: high-water 鮮度トリガー列の追加（issue #26）。
    app.migrations.add(AddHighWaterToCompanyFinancials())
    // Stage 5: 有報セクション本文（company_filing_sections、書類単位 JSONB）。
    app.migrations.add(CreateCompanyFilingSections())
    // EDINET マスタデータ（コードリスト CSV）の正本スナップショット（単一行）。
    app.migrations.add(CreateEdinetMasterSnapshot())
    // Stage 6: 事業別内訳（company_breakdowns、書類×軸単位 JSONB）。
    app.migrations.add(CreateCompanySegmentBreakdowns())
    // company_segment_breakdowns → company_breakdowns へのテーブル名変更（Breakdown 系命名への統一）。
    app.migrations.add(RenameCompanySegmentBreakdownsToCompanyBreakdowns())
    // business 軸が解決できなかった理由（E/F/unknown）の永続化列（issue #132）。
    app.migrations.add(AddNotApplicableReasonToCompanyBreakdowns())
    // Stage 7: BS/PL/CF 完全正規化（company_statements、書類単位 JSONB）。対象は日経225限定。
    app.migrations.add(CreateCompanyStatements())
    try await withDbRetry(
        operationTimeoutSeconds: Api.dbBootstrapOperationTimeoutSeconds,
        logger: app.logger,
        context: "autoMigrate"
    ) {
        try await app.autoMigrate()
    }

    app.logger.notice("Postgres (Neon) を登録し、マイグレーションを適用しました。")
}
