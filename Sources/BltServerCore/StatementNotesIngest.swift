// 財務諸表注記取り込み: 日経225構成銘柄の有報について note_type 別の財務諸表注記を解決し
// company_statement_notes へ upsert する。解決は BlueTickerCore のファサード
// （resolveStatementNote 系）に委譲し、ここでは対象選定・staleness 判定・DB upsert のみを担う
// （ネットワーク非依存でテスト可能）。内訳取り込み（`BreakdownIngest.swift`）の axis 別構造をそのまま
// note_type 別に踏襲する。呼び出し元（`FactsIngest.swift`）が note_type ごとに本関数を呼ぶ。
//
// 対象は Statement 取り込み と同じ日経225構成銘柄に限定する（呼び出し元
// `FactsIngest.swift` が `priorityIngestCodes()` を `filingSectionCandidates` の `listedCodes`
// 引数として渡すことで実現する）。候補選定ロジックは 有報セクション取り込み・内訳取り込み・
// Statement 取り込み と同じ `filingSectionCandidates` を再利用する。
//
// staleness 判定は 内訳取り込み と同型（`docs/breakdown.md`）。
// - xbrl_facts / not_applicable 経由（決定的）: cache_version が現行と不一致なら再計算してよい。
// - LLM 経由（source == "llm"）: cache_version のバンプだけでは再計算しない。needs_review が
//   true の行のみ再試行対象にする。

import BlueTickerCore
import Fluent
import Foundation
import Logging

/// 財務諸表注記取り込み結果のサマリ。
public struct StatementNotesIngestSummary: Sendable, Equatable {
    /// 解決を試みた書類数（skip を除く）。
    public let attempted: Int
    /// 解決・格納に成功した書類数。
    public let stored: Int
    /// 書類の取得・抽出自体は成功したが当該 note_type が対象外だった書類数（失敗ではない）。
    public let notApplicable: Int
    /// 取得・抽出失敗でスキップした書類数。
    public let failed: Int
    /// 既に現行版・needs_review=false で解決済みのためスキップした書類数。
    public let skipped: Int
    /// 保持窓（直近 years 件）を超えたため削除した既存行数。
    public let purged: Int
}

/// docID・code を受けて note_type 1つ分の解決結果を返す関数。呼び出し元が note_type ごとに
/// 束縛済みのクロージャを渡す（`BreakdownResolveFn` と同型）。`code` は 財務取り込み 計算結果参照
/// （`company_financials` は code キー）等、docID だけでは引けない参照を resolver 内で行うために渡す。
public typealias StatementNoteResolveFn =
    @Sendable (String, String) async -> StatementNoteResolveResult

/// `listedCodes`（日経225構成銘柄集合）の有報（直近 years 年ぶん）を走査し、未解決 or
/// 再試行対象（needs_review・xbrl_facts のバージョン不一致）のものを解決・格納する。
/// `limit` は新規解決件数の上限。`explicitCodes` / `priorityCodes` は 有報セクション取り込み・
/// 内訳取り込み・Statement 取り込み と同じ意味。`noteType` は `statementNoteType*` 定数のいずれか。
/// `cachedDocIDs` はローカル XBRL 展開済み。処理順は各社の最新有報 → 前年以降。同一年次内は
/// 日経225 → キャッシュ済み → 欠測/要再試行/版ずれのラウンドロビン。
/// `candidateSets` を渡すと候補選定クエリを省略する（呼び出し元がステージ間で候補を共有するとき）。
func runStatementNotesIngest(
    db: Database, listedCodes: Set<String>, years: Int,
    limit: Int?, explicitCodes: Set<String>? = nil, priorityCodes: Set<String> = [],
    cachedDocIDs: Set<String> = [],
    noteType: String,
    candidateSets: FilingSectionCandidateSets? = nil,
    logger: Logger? = nil, resolve: StatementNoteResolveFn
) async throws -> StatementNotesIngestSummary {
    let currentCacheVersion = statementNoteCacheVersion(forType: noteType)
    let sets: FilingSectionCandidateSets
    if let candidateSets {
        sets = candidateSets
    } else {
        sets = try await filingSectionCandidates(
            db: db, listedCodes: listedCodes, explicitCodes: explicitCodes, years: years, logger: logger)
    }
    let baseCandidates = sets.keep

    var attempted = 0
    var stored = 0
    var notApplicable = 0
    var failed = 0
    var skipped = 0
    var unhealthyRetries = 0
    var missing: [FilingDocCandidate] = []
    var flaggedForReview: [FilingDocCandidate] = []
    var staleVersion: [FilingDocCandidate] = []

    let classifyRows = try await withDbRetry(
        logger: logger, context: "財務諸表注記取り込み(\(noteType)) 分類", onRetry: { unhealthyRetries += 1 }
    ) {
        try await CompanyStatementNoteSourceVersionOnly.query(on: db)
            .filter(\.$noteType == noteType)
            .all()
    }
    let classifyIndex = ingestIndexByID(classifyRows) { $0.id }

    for cand in baseCandidates {
        let key = CompanyStatementNote.compositeID(docID: cand.docID, noteType: noteType)
        guard let existing = classifyIndex[key] else {
            missing.append(cand)
            continue
        }
        if existing.needsReview {
            flaggedForReview.append(cand)
        } else if isVersionGatedStatementNoteSource(existing.source),
            existing.cacheVersion != currentCacheVersion
        {
            staleVersion.append(cand)
        } else {
            skipped += 1
        }
    }
    let candidates = ingestOrderedByYearRank(
        [missing, flaggedForReview, staleVersion],
        docIDOf: \.docID, codeOf: \.code, yearRankOf: \.yearRank,
        cachedDocIDs: cachedDocIDs, priorityCodes: priorityCodes)
    // 分類フェーズと実処理フェーズでリトライ予算を分ける。
    unhealthyRetries = 0

    for cand in candidates {
        if unhealthyRetries >= Api.ingestDbUnhealthyRetryThreshold {
            logger?.error(
                "DB接続が不安定なため 財務諸表注記取り込み(\(noteType)) を中断します(リトライ\(unhealthyRetries)回・残り\(candidates.count - attempted)件は次回スケジュールで再試行)"
            )
            break
        }
        let key = CompanyStatementNote.compositeID(docID: cand.docID, noteType: noteType)
        let existing = try await withDbRetry(
            logger: logger, context: "docID=\(cand.docID)", onRetry: { unhealthyRetries += 1 }
        ) {
            try await CompanyStatementNote.find(key, on: db)
        }
        if let row = existing, row.needsReview == false,
            !isVersionGatedStatementNoteSource(row.source) || row.cacheVersion == currentCacheVersion
        {
            skipped += 1
            continue
        }
        if let lim = limit, attempted >= lim { break }
        attempted += 1

        switch await resolve(cand.docID, cand.code) {
        case .resolved(let payload, let source, let contentHash):
            try await withDbRetry(
                logger: logger, context: "docID=\(cand.docID)", onRetry: { unhealthyRetries += 1 }
            ) {
                try await storeStatementNote(
                    existing: existing, docID: cand.docID, noteType: noteType,
                    code: cand.code, submitDateTime: cand.submitDateTime, payload: payload,
                    source: source, contentHash: contentHash, cacheVersion: currentCacheVersion,
                    db: db)
            }
            stored += 1
        case .notApplicable(let reason):
            notApplicable += 1
            if let existing, existing.source != statementNoteSourceNotApplicable {
                logger?.warning(
                    "財務諸表注記取り込み(\(noteType)): 既存の実データ行を notApplicable(\(reason)) で上書きしません(次回再試行): docID=\(cand.docID) code=\(cand.code)"
                )
            } else {
                let placeholder = StatementNotePayload(
                    needsReview: false, warnings: [])
                try await withDbRetry(
                    logger: logger, context: "docID=\(cand.docID)", onRetry: { unhealthyRetries += 1 }
                ) {
                    try await storeStatementNote(
                        existing: existing, docID: cand.docID, noteType: noteType,
                        code: cand.code, submitDateTime: cand.submitDateTime,
                        payload: placeholder, source: statementNoteSourceNotApplicable,
                        contentHash: "", cacheVersion: currentCacheVersion,
                        notApplicableReason: reason, db: db)
                }
            }
        case .failed:
            failed += 1
            logger?.warning("財務諸表注記取り込み(\(noteType)) 取り込み失敗: docID=\(cand.docID) code=\(cand.code)")
        }
    }

    // 保持窓を超えた既存行を purge する。分類・実処理フェーズとは別のリトライ予算を使う。
    unhealthyRetries = 0
    var purged = 0
    if !sets.purge.isEmpty {
        let purgeDocIDs = Set(sets.purge)
        purged = try await withDbRetry(
            logger: logger, context: "財務諸表注記取り込み(\(noteType)) purge", onRetry: { unhealthyRetries += 1 }
        ) {
            let n = try await CompanyStatementNote.query(on: db)
                .filter(\.$noteType == noteType)
                .filter(\.$docID ~~ purgeDocIDs)
                .count()
            if n > 0 {
                try await CompanyStatementNote.query(on: db)
                    .filter(\.$noteType == noteType)
                    .filter(\.$docID ~~ purgeDocIDs)
                    .delete()
            }
            return n
        }
    }

    return StatementNotesIngestSummary(
        attempted: attempted, stored: stored, notApplicable: notApplicable,
        failed: failed, skipped: skipped, purged: purged)
}

/// 解決済み注記を company_statement_notes へ書き込む（既存行があれば更新、無ければ作成）。
/// `notApplicableReason` は `source == statementNoteSourceNotApplicable` の行にのみ渡す（省略時 nil）。
func storeStatementNote(
    existing: CompanyStatementNote?, docID: String, noteType: String, code: String,
    submitDateTime: String, payload: StatementNotePayload, source: String, contentHash: String,
    cacheVersion: String, notApplicableReason: String? = nil, db: Database
) async throws {
    let applyFields: (CompanyStatementNote) -> Void = { row in
        row.code = code
        row.submitDateTime = submitDateTime
        row.payload = payload
        row.needsReview = payload.needsReview
        row.source = source
        row.contentHash = contentHash
        row.cacheVersion = cacheVersion
        row.notApplicableReason = notApplicableReason
    }
    if let row = existing {
        applyFields(row)
        try await row.update(on: db)
    } else {
        let model = CompanyStatementNote(docID: docID, noteType: noteType)
        applyFields(model)
        try await createIdempotently(
            create: { try await model.create(on: db) },
            recover: {
                let key = CompanyStatementNote.compositeID(docID: docID, noteType: noteType)
                guard let recovered = try await CompanyStatementNote.find(key, on: db) else {
                    return false
                }
                applyFields(recovered)
                try await recovered.update(on: db)
                return true
            }
        )
    }
}

// MARK: - read 経路（REST/MCP statement notes）

/// `loadStoredStatementNote` の結果3値。`BreakdownLoadResult`（内訳取り込み）と同型
/// （「行が無い/read不可」と「行はあるが対象外だった（reason付き）」を区別する）。
enum StatementNoteLoadResult {
    /// 実データあり。公開契約 {code, doc_id, note_type, note} の JSON。
    case found([String: Any])
    /// 行はあるが当該 note_type が対象外だった（`statementNoteNotApplicable*` のいずれか）。
    case notApplicable(reason: String)
    /// 行が無い、または read 不可（バージョン床未満等）。
    case absent
}

/// 格納済み 財務諸表注記取り込み 注記を引いて公開契約 {code, doc_id, note_type, note} を返す。
/// `noteType` は `statementNoteType*` 定数のいずれか（未知の note_type は absent）。
/// doc_id 指定時はその書類（当該 code のもの）、省略時は当該 code の最新有報（提出日時降順のうち read 可能な先頭）。
/// read 可否は `isServableStatementNote`（xbrl_facts/not_applicable はバージョン床、LLM 経由は常に可）。
/// 無い・read 不可なら `.absent`（呼び出し側は 404。ライブ解決へはフォールバックしない）。
func loadStoredStatementNote(
    code: String, docId: String?, noteType: String, db: Database
) async throws -> StatementNoteLoadResult {
    let code4 = String(code.prefix(4))
    guard !code4.isEmpty, code4.allSatisfy({ $0.isLetter || $0.isNumber }) else { return .absent }
    guard !statementNoteCacheVersion(forType: noteType).isEmpty else { return .absent }

    let row: CompanyStatementNote?
    if let docId, !docId.isEmpty {
        let key = CompanyStatementNote.compositeID(docID: docId, noteType: noteType)
        let found = try await CompanyStatementNote.find(key, on: db)
        row = (found?.code == code4) ? found : nil
    } else {
        let candidates = try await CompanyStatementNote.query(on: db)
            .filter(\.$code == code4)
            .filter(\.$noteType == noteType)
            .sort(\.$submitDateTime, .descending)
            .all()
        row = candidates.first {
            isServableStatementNote(source: $0.source, cacheVersion: $0.cacheVersion, noteType: noteType)
        }
    }

    guard let row,
        isServableStatementNote(source: row.source, cacheVersion: row.cacheVersion, noteType: noteType),
        let docID = row.id?.components(separatedBy: "#").first
    else { return .absent }

    if let reason = row.notApplicableReason {
        return .notApplicable(reason: reason)
    }

    return .found([
        "code": code4,
        "doc_id": docID,
        "note_type": row.noteType,
        "note": row.payload.jsonObject(),
    ])
}

// MARK: - servable/unservable 集計

/// `source`/`cache_version`/`note_type` を対象にした軽量射影（`payload` の JSONB を転送しない）。
/// company_statement_notes 全件の servable/unservable 集計用。
final class CompanyStatementNoteSourceVersionOnly: Model, @unchecked Sendable {
    static let schema = CompanyStatementNote.schema

    @ID(custom: "id", generatedBy: .user)
    var id: String?

    @Field(key: "source")
    var source: String

    @Field(key: "cache_version")
    var cacheVersion: String

    @Field(key: "note_type")
    var noteType: String

    @Field(key: "needs_review")
    var needsReview: Bool

    init() {}
}

/// company_statement_notes 全件を read 可否（`isServableStatementNote`）で集計する。
func countServableStatementNotes(db: Database) async throws -> (servable: Int, unservable: Int) {
    let rows = try await CompanyStatementNoteSourceVersionOnly.query(on: db).all()
    let servable = rows.filter {
        isServableStatementNote(source: $0.source, cacheVersion: $0.cacheVersion, noteType: $0.noteType)
    }.count
    return (servable, rows.count - servable)
}
