// Fluent（DB 層）の配線。
// DATABASE_URL（Neon の Postgres 接続文字列）が設定されているときのみ Postgres を登録する。
// 未設定なら DB なしで起動する（現行のステートレス EDINET プロキシ動作を維持）。
//
// マイグレーション（DDL）は書き込み側のコマンド（`migrate` と sync / ingest などの取り込み系）だけが
// 適用する。配信サーバー（`runBltServer`）と read 専用コマンドは `.readOnly` で登録だけ行い、
// 読み取りロール（blt_reader）でも起動できるようにする。
//
// `autoMigrate` は withDbRetry で包む。ingest 本体の DB 操作は既にリトライ済みだが、
// プロセス起動直後の初回接続（Neon cold start）はここが唯一の接点で、失敗すると
// sync/ingest 全体が connectionRequestTimeout で即死するため。

import BlueTickerCore
import Fluent
import FluentPostgresDriver
import Vapor

/// `configureDatabase` がマイグレーションを適用するか。
public enum DatabaseSchemaMode: Sendable {
    /// 接続を登録するだけ。DDL を出さない（配信サーバー・read 専用コマンド）。
    case readOnly
    /// 未適用のマイグレーションを適用する（書き込み側のコマンドだけ）。
    case migrate
}

/// DATABASE_URL があれば Postgres を `.psql` として登録する。`.migrate` のときだけ未適用のマイグレーションを実行する。
/// TLS / sslmode は接続 URL のクエリ（例: `?sslmode=require`）から解決される（Neon は TLS 必須）。
func configureDatabase(_ app: Application, schema: DatabaseSchemaMode) async throws {
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

    guard schema == .migrate else {
        app.logger.notice("Postgres (Neon) を登録しました（マイグレーションは適用しない）。")
        return
    }
    registerBltMigrations(app.migrations)
    try await withDbRetry(
        operationTimeoutSeconds: Api.dbBootstrapOperationTimeoutSeconds,
        logger: app.logger,
        context: "autoMigrate"
    ) {
        try await app.autoMigrate()
    }

    app.logger.notice("Postgres (Neon) を登録し、マイグレーションを適用しました。")
}

/// 本番スキーマのマイグレーションを適用順に登録する（正本。テストもここから全件を取る）。
func registerBltMigrations(_ migrations: Migrations) {
    // 書類同期: 書類一覧（edinet_documents）と同期進捗（edinet_sync_state）。
    migrations.add(CreateEdinetDocument())
    migrations.add(AddParentDocIDToEdinetDocuments())
    migrations.add(CreateEdinetSyncState())
    // 数値 fact 取り込み: XBRL 数値 RAW（edinet_xbrl_facts、書類単位 JSONB）。
    migrations.add(CreateEdinetXbrlFacts())
    // 財務取り込み: 計算済み財務サマリ（company_financials、企業単位 JSONB）。
    migrations.add(CreateCompanyFinancials())
    // 半期財務取り込み（凍結済み・削除しない。テーブルは DropCompanyHalfFinancials で削除）。
    migrations.add(CreateCompanyHalfFinancials())
    // 財務取り込み: high-water 鮮度トリガー列の追加（issue #26）。
    migrations.add(AddHighWaterToCompanyFinancials())
    // 財務取り込み: 正本 cache_version 指紋（タスク #11。fin-vN 非連動の再組立トリガ）。
    migrations.add(AddAssemblyFingerprintToCompanyFinancials())
    // 財務取り込み: Summary sga の Jev 監査（公開 response には出さない）。
    migrations.add(AddLlmAuditToCompanyFinancials())
    // 有報セクション取り込み: 有報セクション本文（company_filing_sections、書類単位 JSONB）。
    migrations.add(CreateCompanyFilingSections())
    // EDINET マスタデータ（コードリスト CSV）の正本スナップショット（単一行）。
    migrations.add(CreateEdinetMasterSnapshot())
    // 内訳取り込み: 事業別内訳（company_breakdowns、書類×軸単位 JSONB）。
    migrations.add(CreateCompanySegmentBreakdowns())
    // company_segment_breakdowns → company_breakdowns へのテーブル名変更（Breakdown 系命名への統一）。
    migrations.add(RenameCompanySegmentBreakdownsToCompanyBreakdowns())
    // product_service 軸が解決できなかった理由（E/F/unknown）の永続化列（issue #132）。
    migrations.add(AddNotApplicableReasonToCompanyBreakdowns())
    // Statement 取り込み: BS/PL/CF/SS 完全正規化（company_statements、書類単位 JSONB）。対象は上場全体。
    migrations.add(CreateCompanyStatements())
    // 財務諸表注記取り込み: company_statement_notes（書類×note_type単位 JSONB）。対象は上場全体。
    migrations.add(CreateCompanyStatementNotes())
    // 半期分析機能の削除に伴い company_half_financials テーブルを削除（不可逆）。
    migrations.add(DropCompanyHalfFinancials())
    // 会社アイコン取り込み: favicon の R2 格納先メタデータ（company_icons、会社単位）。
    migrations.add(CreateCompanyIcons())
    // 銘柄 Overview: 短い会社説明（company_overviews、会社単位 JSONB）。ingest stage は `overviews`。
    migrations.add(CreateCompanyOverviews())
    // Feed Update: 提出日時の読み取り索引。
    migrations.add(AddFeedQueryIndexesToEdinetDocuments())
    migrations.add(AddCodeSubmitDateTimeIndexes())
    // Screen: company_financials 最新 FY の 1 社 1 行 Read Model（screen_index、BLT-49）。
    migrations.add(CreateScreenIndex())
    migrations.add(ReplaceScreenIndexGrowthWithCagr())
    migrations.add(AddCacheVersionToScreenIndex())
    migrations.add(AddScreenV3MetricsToScreenIndex())
    migrations.add(AddScreenCagrMetricsToScreenIndex())
    migrations.add(AddScreenPayoutRatio3yToScreenIndex())
    migrations.add(CreateManualXbrlOverrides())
    migrations.add(RestrictManualXbrlOverridesToCapex())
    // 関係取り込み: 顧客・関係会社・出資先・大株主（company_relations、書類×相手単位）。stage は `relations`。
    migrations.add(CreateCompanyRelations())
    migrations.add(AddVotingRatioDetailToCompanyRelations())
}

/// `blt-server migrate` エントリ。DATABASE_URL のスキーマへ未適用のマイグレーションだけを適用する。
/// 配信サーバーは起動時に migrate しないため、マイグレーションを含む変更は
/// Fly へデプロイする前に Mac からこれを実行する（docs/ingest-policy.md「出荷順」）。
public func runMigrateCommand() async throws {
    guard let urlString = Environment.get("DATABASE_URL"), !urlString.isEmpty else {
        throw DocumentSyncError.databaseUnavailable
    }
    var env = Environment(name: "production", arguments: ["blt-server"])
    try bootstrapBltLogging(from: &env)
    let app = try await Application.make(env)
    do {
        try await configureDatabase(app, schema: .migrate)
    } catch {
        try? await app.asyncShutdown()
        throw error
    }
    try await app.asyncShutdown()
}
