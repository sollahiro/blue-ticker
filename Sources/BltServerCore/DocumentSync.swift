// 書類同期: EDINET 書類一覧を DB（edinet_documents）へ取り込み、
// 同期高水位（edinet_sync_state.synced_through）を進める。
// 取得・正規化は BlueTickerCore のファサード（fetchDocumentsForSync）に委譲し、
// ここでは DB への upsert と高水位更新のみを担う。

import BlueTickerCore
import Fluent
import Foundation
import Vapor

/// 同期結果のサマリ。
public struct DocumentSyncSummary: Sendable, Equatable {
    public let from: String
    public let to: String
    /// 実際に DB へ書き込んだ synced_through（部分失敗時は to より前になる）。
    public let syncedThrough: String
    public let fetched: Int
    public let created: Int
    public let updated: Int
}

enum DocumentSyncError: Error, CustomStringConvertible {
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
            return "EDINET API キーが未設定です。BLT_EDINET_API_KEY 環境変数を設定してください。"
        }
    }
}

/// EDINET 書類を期間取得して DB へ upsert し、synced_through を to へ進める。
/// from 解決順位: 明示指定 > 既存 synced_through > （いずれも無ければ）missingStartDate。
func runDocumentSync(
    context: BltServerContext,
    db: Database,
    from: String?,
    to: String,
    logger: Logger? = nil
) async throws -> DocumentSyncSummary {
    let resolvedFrom = try await resolveStartDate(from: from, db: db, logger: logger)
    let previousSyncedThrough = try await loadSyncedThrough(db: db, logger: logger)
    let fetchResult = await context.fetchDocumentsForSync(from: resolvedFrom, to: to)
    let counts = try await applyDocuments(fetchResult.records, db: db, logger: logger)
    let syncedThrough = computeDocumentSyncedThrough(
        from: resolvedFrom,
        to: to,
        previousSyncedThrough: previousSyncedThrough,
        applyCompleted: counts.completed,
        failedFetchDates: fetchResult.failedDates
    )
    if syncedThrough != to {
        logger?.warning(
            "書類同期を部分完了: requested_to=\(to) synced_through=\(syncedThrough) apply_completed=\(counts.completed) failed_fetch_days=\(fetchResult.failedDates.count)"
        )
    }
    try await upsertSyncState(syncedThrough: syncedThrough, db: db, logger: logger)

    return DocumentSyncSummary(
        from: resolvedFrom, to: to, syncedThrough: syncedThrough,
        fetched: fetchResult.records.count,
        created: counts.created, updated: counts.updated)
}

/// レコードを edinet_documents へ upsert する（docID 一致で更新、無ければ作成）。
/// 各 DB 操作は withDbRetry で一過性の接続断（Neon scale-to-zero 等）に対して再試行する
/// （EDINET 取得の空白中に suspend され、直後の DB 操作が死んだ接続で失敗するのを回復。ingest と同思想）。
func applyDocuments(
    _ records: [EdinetDocumentRecord], db: Database, logger: Logger? = nil
) async throws -> (created: Int, updated: Int, completed: Bool) {
    var created = 0
    var updated = 0
    var unhealthyRetries = 0
    for record in records {
        // 他ステージと同様、各項目の先頭で判定する（本ループに continue は無いが一貫性のため）。
        if unhealthyRetries >= Api.ingestDbUnhealthyRetryThreshold {
            logger?.error(
                "DB接続が不安定なため 書類同期 sync を中断します(リトライ\(unhealthyRetries)回・残り\(records.count - created - updated)件は次回スケジュールで再試行)"
            )
            return (created, updated, completed: false)
        }
        let existing = try await withDbRetry(
            logger: logger, context: "docID=\(record.docID)", onRetry: { unhealthyRetries += 1 }
        ) {
            try await EdinetDocument.find(record.docID, on: db)
        }
        if let existing {
            existing.apply(record)
            try await withDbRetry(
                logger: logger, context: "docID=\(record.docID)",
                onRetry: { unhealthyRetries += 1 }
            ) { try await existing.update(on: db) }
            updated += 1
        } else {
            try await withDbRetry(
                logger: logger, context: "docID=\(record.docID)",
                onRetry: { unhealthyRetries += 1 }
            ) {
                // モデルはリトライ試行のたびに新規生成する（withOperationTimeout の既知の
                // トレードオフにより、タイムアウト後も切り離されたタスクが遅延完了することがあり、
                // 同一インスタンスを試行間で使い回すと Fluent の `_$idExists` 二重更新で precondition
                // が trap しうるため）。
                let model = EdinetDocument()
                model.id = record.docID
                model.apply(record)
                try await createIdempotently(
                    create: { try await model.create(on: db) },
                    recover: {
                        guard let recovered = try await EdinetDocument.find(record.docID, on: db)
                        else { return false }
                        recovered.apply(record)
                        try await recovered.update(on: db)
                        return true
                    }
                )
            }
            created += 1
        }
    }
    return (created, updated, completed: true)
}

/// 部分失敗時は高水位を進めない（または取得失敗日の前日までに留める）。
func computeDocumentSyncedThrough(
    from: String,
    to: String,
    previousSyncedThrough: String?,
    applyCompleted: Bool,
    failedFetchDates: [String]
) -> String {
    guard applyCompleted else {
        return previousSyncedThrough ?? from
    }
    var advanceTo = to
    if let earliestFailed = failedFetchDates.filter({ $0 >= from && $0 <= to }).sorted().first,
       let dayBefore = dayBeforeISO(earliestFailed) {
        advanceTo = min(advanceTo, dayBefore)
    }
    return advanceTo
}

/// 現在の synced_through を読む（未作成なら nil）。
func loadSyncedThrough(db: Database, logger: Logger? = nil) async throws -> String? {
    try await withDbRetry(logger: logger, context: "sync_state") {
        try await EdinetSyncState.find(EdinetSyncState.singletonID, on: db)?.syncedThrough
    }
}

/// from 解決順位: 明示指定 > 既存 synced_through > missingStartDate。
func resolveStartDate(from: String?, db: Database, logger: Logger? = nil) async throws -> String {
    if let f = from, !f.isEmpty { return f }
    let state = try await withDbRetry(logger: logger, context: "sync_state") {
        try await EdinetSyncState.find(EdinetSyncState.singletonID, on: db)
    }
    if let state { return state.syncedThrough }
    throw DocumentSyncError.missingStartDate
}

/// synced_through を upsert する（単一行）。
func upsertSyncState(syncedThrough: String, db: Database, logger: Logger? = nil) async throws {
    let state = try await withDbRetry(logger: logger, context: "sync_state") {
        try await EdinetSyncState.find(EdinetSyncState.singletonID, on: db)
    } ?? EdinetSyncState()
    state.id = EdinetSyncState.singletonID
    state.syncedThrough = syncedThrough
    try await withDbRetry(logger: logger, context: "sync_state") { try await state.save(on: db) }
}

// MARK: - read 経路（REST filings）

/// 指定銘柄（4 桁証券コード）の 書類同期 書類を DB から引いて正規化レコードで返す。
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
public func runDocumentSyncCommand(from: String?, to: String?) async throws {
    guard let context = await makeBltServerContext() else {
        throw DocumentSyncError.apiKeyMissing
    }
    guard let urlString = Environment.get("DATABASE_URL"), !urlString.isEmpty else {
        throw DocumentSyncError.databaseUnavailable
    }

    var env = Environment(name: "production", arguments: ["blt-server"])
    try bootstrapBltLogging(from: &env)
    let app = try await Application.make(env)
    do {
        try await configureDatabase(app)
        let summary = try await runDocumentSync(
            context: context, db: app.db, from: from, to: to ?? todayUTC(), logger: app.logger)
        app.logger.notice(
            "書類同期 sync summary",
            metadata: [
                "event": "sync_summary",
                "target": "documents",
                "from": .string(summary.from),
                "to": .string(summary.to),
                "synced_through": .string(summary.syncedThrough),
                "fetched": .stringConvertible(summary.fetched),
                "created": .stringConvertible(summary.created),
                "updated": .stringConvertible(summary.updated),
            ])
    } catch {
        try? await app.asyncShutdown()
        throw error
    }
    try await app.asyncShutdown()
}
