// マイグレーション（DDL）の正本と適用。DDL を出すのは blt-ingest（Mac の書き込み側）だけ。
// `migrate` と sync / ingest などの取り込み系コマンドが冒頭で適用する。配信サーバー（blt-server）は
// 起動時に適用せず、読み取りロール（blt_reader）で動く（docs/ingest-policy.md「出荷順」）。
//
// 適用は withDbRetry で包む。ingest 本体の DB 操作は既にリトライ済みだが、
// プロセス起動直後の初回接続（Neon cold start）はここが唯一の接点で、失敗すると
// sync/ingest 全体が connectionRequestTimeout で即死するため。

import BltStoreCore
import BlueTickerCore
import FluentKit

/// 未適用のマイグレーションだけを適用する（Vapor の `autoMigrate` と同じ手順）。
func migrateBltSchema(_ conn: BltCommandDatabase) async throws {
    let migrations = Migrations()
    registerBltMigrations(migrations)
    let migrator = Migrator(
        databases: conn.databases, migrations: migrations, logger: conn.logger,
        on: conn.databases.eventLoopGroup.any())
    try await withDbRetry(
        operationTimeoutSeconds: Api.dbBootstrapOperationTimeoutSeconds,
        logger: conn.logger,
        context: "autoMigrate"
    ) {
        try await migrator.setupIfNeeded().get()
        try await migrator.prepareBatch().get()
    }
    conn.logger.notice("Postgres (Neon) のマイグレーションを適用しました。")
}

/// DATABASE_URL へ接続し、マイグレーションを適用してから body を実行する（書き込み側コマンドの共通入口）。
/// DATABASE_URL 未設定なら databaseUnavailable。
func withIngestDatabase<T>(_ body: (BltCommandDatabase) async throws -> T) async throws -> T {
    guard let conn = try BltCommandDatabase.connectFromEnvironment(label: "blt-ingest") else {
        throw DocumentSyncError.databaseUnavailable
    }
    let result: T
    do {
        try await migrateBltSchema(conn)
        result = try await body(conn)
    } catch {
        await conn.asyncShutdown()
        throw error
    }
    await conn.asyncShutdown()
    return result
}

/// 本番スキーマのマイグレーションを適用順に登録する（正本。テストもここから全件を取る）。
package func registerBltMigrations(_ migrations: Migrations) {
    // 書類同期: 書類一覧（edinet_documents）と同期進捗（edinet_sync_state）。
    migrations.add(CreateEdinetDocument())
    migrations.add(AddParentDocIDToEdinetDocuments())
    migrations.add(CreateEdinetSyncState())
    // 数値 fact 投影（閉じた。Create は履歴維持、テーブルは DropEdinetXbrlFacts で削除）。
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
    // 閉じた数値 fact 投影テーブル edinet_xbrl_facts を削除（不可逆。IF EXISTS）。
    migrations.add(DropEdinetXbrlFacts())
}

/// `blt-ingest migrate` エントリ。DATABASE_URL のスキーマへ未適用のマイグレーションだけを適用する。
/// 配信サーバーは起動時に migrate しないため、マイグレーションを含む変更は
/// Fly へデプロイする前に Mac からこれを実行する（docs/ingest-policy.md「出荷順」）。
public func runMigrateCommand() async throws {
    try await withIngestDatabase { _ in }
}
