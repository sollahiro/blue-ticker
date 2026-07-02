// Stage 1 同期: EDINET 書類一覧を DB（edinet_documents）へ取り込み、
// 同期高水位（edinet_sync_state.synced_through）を進める。
// 取得・正規化は BlueTickerCore のファサード（fetchDocumentsForSync）に委譲し、
// ここでは DB への upsert と高水位更新のみを担う。

import BlueTickerCore
import Fluent
import Foundation
import Vapor

/// 同期結果のサマリ。
public struct Stage1SyncSummary: Sendable, Equatable {
    public let from: String
    public let to: String
    public let fetched: Int
    public let created: Int
    public let updated: Int
}

enum Stage1SyncError: Error, CustomStringConvertible {
    /// 初回同期で開始日が決められない（同期状態なし・--from 未指定）。
    case missingStartDate
    /// DATABASE_URL 未設定で DB が無い。
    case databaseUnavailable
    /// EDINET API キーが未設定。
    case apiKeyMissing

    var description: String {
        switch self {
        case .missingStartDate:
            return "初回同期では --from YYYY-MM-DD で開始日を指定してください（同期状態が未作成のため）。"
        case .databaseUnavailable:
            return "DATABASE_URL が未設定です。同期には DB 接続が必要です。"
        case .apiKeyMissing:
            return "EDINET API キーが未設定です。BLT_EDINET_API_KEY 環境変数、または ticker config set --edinet-api-key <KEY> で設定してください。"
        }
    }
}

/// EDINET 書類を期間取得して DB へ upsert し、synced_through を to へ進める。
/// from 解決順位: 明示指定 > 既存 synced_through > （いずれも無ければ）missingStartDate。
func runStage1Sync(
    context: BltServerContext,
    db: Database,
    from: String?,
    to: String,
    logger: Logger? = nil
) async throws -> Stage1SyncSummary {
    let resolvedFrom = try await resolveStartDate(from: from, db: db, logger: logger)
    let records = await context.fetchDocumentsForSync(from: resolvedFrom, to: to)
    let counts = try await applyDocuments(records, db: db, logger: logger)
    try await upsertSyncState(syncedThrough: to, db: db, logger: logger)

    return Stage1SyncSummary(
        from: resolvedFrom, to: to, fetched: records.count,
        created: counts.created, updated: counts.updated)
}

/// レコードを edinet_documents へ upsert する（docID 一致で更新、無ければ作成）。
/// 各 DB 操作は withDbRetry で一過性の接続断（Neon scale-to-zero 等）に対して再試行する
/// （EDINET 取得の空白中に suspend され、直後の DB 操作が死んだ接続で失敗するのを回復。ingest と同思想）。
func applyDocuments(
    _ records: [EdinetDocumentRecord], db: Database, logger: Logger? = nil
) async throws -> (created: Int, updated: Int) {
    var created = 0
    var updated = 0
    for record in records {
        let existing = try await withDbRetry(logger: logger) {
            try await EdinetDocument.find(record.docID, on: db)
        }
        if let existing {
            existing.apply(record)
            try await withDbRetry(logger: logger) { try await existing.update(on: db) }
            updated += 1
        } else {
            let model = EdinetDocument()
            model.id = record.docID
            model.apply(record)
            try await withDbRetry(logger: logger) { try await model.create(on: db) }
            created += 1
        }
    }
    return (created, updated)
}

/// from 解決順位: 明示指定 > 既存 synced_through > missingStartDate。
func resolveStartDate(from: String?, db: Database, logger: Logger? = nil) async throws -> String {
    if let f = from, !f.isEmpty { return f }
    let state = try await withDbRetry(logger: logger) {
        try await EdinetSyncState.find(EdinetSyncState.singletonID, on: db)
    }
    if let state { return state.syncedThrough }
    throw Stage1SyncError.missingStartDate
}

/// synced_through を upsert する（単一行）。
func upsertSyncState(syncedThrough: String, db: Database, logger: Logger? = nil) async throws {
    let state = try await withDbRetry(logger: logger) {
        try await EdinetSyncState.find(EdinetSyncState.singletonID, on: db)
    } ?? EdinetSyncState()
    state.id = EdinetSyncState.singletonID
    state.syncedThrough = syncedThrough
    try await withDbRetry(logger: logger) { try await state.save(on: db) }
}

// MARK: - read 経路（REST filings）

/// 指定銘柄（4 桁証券コード）の Stage 1 書類を DB から引いて正規化レコードで返す。
/// EDINET の secCode は 5 桁（4 桁＋種別 1 桁）のため LIKE プレフィックスで突き合わせる
/// （ライブ探索の hasPrefix(code4) と同条件）。該当 0 件なら空配列（呼び出し側はライブ探索へフォールバック）。
func loadStoredFilingRecords(code: String, db: Database) async throws -> [EdinetDocumentRecord] {
    let code4 = String(code.prefix(4))
    // 証券コードは英数字のみ。LIKE プレフィックス突き合わせのため、ワイルドカード
    // （% / _）等の混入を弾く（不正コードは空 → 呼び出し側がライブ探索へフォールバック）。
    guard !code4.isEmpty, code4.allSatisfy({ $0.isLetter || $0.isNumber }) else { return [] }
    let rows = try await EdinetDocument.query(on: db)
        .filter(\.$secCode, .contains(inverse: false, .prefix), code4)
        .all()
    return rows.map { $0.toRecord() }
}

extension EdinetDocument {
    /// DB モデル → 正規化済みレコード（read 経路でファサードへ渡す）。
    func toRecord() -> EdinetDocumentRecord {
        EdinetDocumentRecord(
            docID: id ?? "",
            edinetCode: edinetCode,
            secCode: secCode,
            filerName: filerName,
            docTypeCode: docTypeCode,
            ordinanceCode: ordinanceCode,
            formCode: formCode,
            periodStart: periodStart,
            periodEnd: periodEnd,
            submitDateTime: submitDateTime,
            docDescription: docDescription)
    }

    /// 正規化済みレコードの値を自身へ写す（id は呼び出し側で設定済み）。
    func apply(_ record: EdinetDocumentRecord) {
        edinetCode = record.edinetCode
        secCode = record.secCode
        filerName = record.filerName
        docTypeCode = record.docTypeCode
        ordinanceCode = record.ordinanceCode
        formCode = record.formCode
        periodStart = record.periodStart
        periodEnd = record.periodEnd
        submitDateTime = record.submitDateTime
        docDescription = record.docDescription
    }
}

// MARK: - CLI エントリ

/// `blt-server sync` の本体。Application を一時的に起動して DB を配線し、同期を実行する。
/// to 未指定なら UTC の当日。DATABASE_URL 未設定なら databaseUnavailable を投げる。
public func runStage1SyncCommand(from: String?, to: String?) async throws {
    guard let context = await makeBltServerContext() else {
        throw Stage1SyncError.apiKeyMissing
    }
    guard let urlString = Environment.get("DATABASE_URL"), !urlString.isEmpty else {
        throw Stage1SyncError.databaseUnavailable
    }

    var env = Environment(name: "production", arguments: ["blt-server"])
    try LoggingSystem.bootstrap(from: &env)
    let app = try await Application.make(env)
    do {
        try await configureDatabase(app)
        let summary = try await runStage1Sync(
            context: context, db: app.db, from: from, to: to ?? todayUTC(), logger: app.logger)
        app.logger.notice(
            "Stage 1 同期完了: \(summary.from)..\(summary.to) fetched=\(summary.fetched) created=\(summary.created) updated=\(summary.updated)")
    } catch {
        try? await app.asyncShutdown()
        throw error
    }
    try await app.asyncShutdown()
}
