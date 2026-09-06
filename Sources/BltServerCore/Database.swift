// Fluent（DB 層）の配線。
// DATABASE_URL（Neon の Postgres 接続文字列）が設定されているときのみ Postgres を登録し、
// 書類同期 のマイグレーションを適用する。
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

    // sslmode の明示がない接続文字列は警告を出す（Neon は TLS 必須のため実害は小さいが、
    // 設定ミスの早期検出のため。`disable` 指定は意図的な場合のみ許容する）。
    if !urlString.contains("sslmode=") {
        app.logger.warning(
            "DATABASE_URL に sslmode の指定がありません。本番接続は `?sslmode=require` を明示してください。")
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

    // 書類同期: 書類一覧（edinet_documents）と同期進捗（edinet_sync_state）。
    app.migrations.add(CreateEdinetDocument())
    app.migrations.add(CreateEdinetSyncState())
    // 数値 fact 取り込み: XBRL 数値 RAW（edinet_xbrl_facts、書類単位 JSONB）。
    app.migrations.add(CreateEdinetXbrlFacts())
    // 財務取り込み: 計算済み財務サマリ（company_financials、企業単位 JSONB）。
    app.migrations.add(CreateCompanyFinancials())
    // 半期財務取り込み（凍結済み・削除しない。テーブルは DropCompanyHalfFinancials で削除）。
    app.migrations.add(CreateCompanyHalfFinancials())
    // 財務取り込み: high-water 鮮度トリガー列の追加（issue #26）。
    app.migrations.add(AddHighWaterToCompanyFinancials())
    // 財務取り込み: 正本 cache_version 指紋（タスク #11。fin-vN 非連動の再組立トリガ）。
    app.migrations.add(AddAssemblyFingerprintToCompanyFinancials())
    // 有報セクション取り込み: 有報セクション本文（company_filing_sections、書類単位 JSONB）。
    app.migrations.add(CreateCompanyFilingSections())
    // EDINET マスタデータ（コードリスト CSV）の正本スナップショット（単一行）。
    app.migrations.add(CreateEdinetMasterSnapshot())
    // 内訳取り込み: 事業別内訳（company_breakdowns、書類×軸単位 JSONB）。
    app.migrations.add(CreateCompanySegmentBreakdowns())
    // company_segment_breakdowns → company_breakdowns へのテーブル名変更（Breakdown 系命名への統一）。
    app.migrations.add(RenameCompanySegmentBreakdownsToCompanyBreakdowns())
    // business 軸が解決できなかった理由（E/F/unknown）の永続化列（issue #132）。
    app.migrations.add(AddNotApplicableReasonToCompanyBreakdowns())
    // Statement 取り込み: BS/PL/CF/SS 完全正規化（company_statements、書類単位 JSONB）。対象は上場全体。
    app.migrations.add(CreateCompanyStatements())
    // 財務諸表注記取り込み: company_statement_notes（書類×note_type単位 JSONB）。対象は日経225限定。
    app.migrations.add(CreateCompanyStatementNotes())
    // 半期分析機能の削除に伴い company_half_financials テーブルを削除（不可逆）。
    app.migrations.add(DropCompanyHalfFinancials())
    // 会社アイコン取り込み: favicon の R2 格納先メタデータ（company_icons、会社単位）。
    app.migrations.add(CreateCompanyIcons())
    // 銘柄 Overview: 短い会社説明（company_overviews、会社単位 JSONB）。ingest stage は `overviews`。
    app.migrations.add(CreateCompanyOverviews())
    // Feed Update: 提出日時の読み取り索引。
    app.migrations.add(AddFeedQueryIndexesToEdinetDocuments())
    app.migrations.add(AddCodeSubmitDateTimeIndexes())
    try await withDbRetry(
        operationTimeoutSeconds: Api.dbBootstrapOperationTimeoutSeconds,
        logger: app.logger,
        context: "autoMigrate"
    ) {
        try await app.autoMigrate()
    }

    app.logger.notice("Postgres (Neon) を登録し、マイグレーションを適用しました。")
}
