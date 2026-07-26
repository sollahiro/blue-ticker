// Stage 6 取り込み: 日経225構成銘柄の有報について business 軸の事業別内訳を解決し
// company_breakdowns へ upsert する。解決は BlueTickerCore のファサード
// （resolveBusinessBreakdown）に委譲し、ここでは対象選定・staleness 判定・DB upsert のみを
// 担う（ネットワーク非依存でテスト可能）。geography 軸は今後の検討事項として未配線（行を作らない）。
//
// 対象は東証上場全体ではなく日経225構成銘柄に限定する（LLM 呼び出し費用を抑えるため。呼び出し元
// `Stage3Ingest.swift` が `priorityIngestCodes()`（`assets/nikkei225.csv`）を `stage5Candidates` の
// `listedCodes` 引数として渡すことで実現する。ファイル未配置時は空集合＝対象0件（安全側））。
//
// 候補選定ロジック自体は Stage 5（`stage5Candidates`、「対象 × 有報(120) × 直近 years 件」）を再利用する
// （事業別内訳は有報と同じ書類集合から取れるため）。年数（`years`）は呼び出し元が Stage 5 と同じ
// `stage5IngestYears` を渡す想定（Stage 6 専用の別値は持たない）。
//
// staleness 判定は Stage 5 と異なる（docs/breakdown-normalization-concept.md「今後の検討事項8」）。
// - xbrl_facts 経由（決定的）: cache_version が現行と不一致なら再計算してよい（安価・再現可能）。
// - LLM 経由（source != xbrl_facts）: cache_version のバンプだけでは再計算しない。needs_review が
//   true の行のみ再試行対象にする（同一 docID の入力は不変のため、content_hash は書き込むが
//   スキップ判定には使わない。抽出ロジックが非決定的になった場合はこの前提が崩れるため、
//   そのときは content_hash 一致チェックの追加を検討する）。

import BlueTickerCore
import Fluent
import Foundation
import Logging

/// company_breakdowns の axis 値。geography 軸は未配線（今後の検討事項）。
let breakdownAxisBusiness = "business"

/// Stage 6 取り込み結果のサマリ。
public struct Stage6IngestSummary: Sendable, Equatable {
    /// 解決を試みた書類数（skip を除く）。
    public let attempted: Int
    /// 解決・格納に成功した書類数。
    public let stored: Int
    /// 書類の取得・抽出自体は成功したが business 軸の内訳が無かった書類数（失敗ではない）。
    public let notApplicable: Int
    /// notApplicable の内訳（issue #130、E/F判定の検知結果明示化）。
    /// E: 報告セグメントが地域別のみで business 軸への swap が見つからなかった書類数。
    public let notApplicableGeographyOnly: Int
    /// F: 単一セグメントのため報告セグメント開示自体が省略されていた書類数。
    public let notApplicableSingleSegmentDisclosed: Int
    /// 上記いずれにも該当しない・原因未特定の書類数（要調査）。
    public let notApplicableUnknown: Int
    /// 取得・抽出失敗でスキップした書類数。
    public let failed: Int
    /// 既に現行版・needs_review=false で解決済みのためスキップした書類数。
    public let skipped: Int
    /// 保持窓（直近 years 件）を超えたため削除した既存行数。
    public let purged: Int
}

/// docID・consolidatedSales を受けて business 軸内訳の解決結果を返す関数。
/// 本番は `context.resolveBusinessBreakdown`、テストはフェイクを注入する。
public typealias BusinessBreakdownResolveFn =
    @Sendable (String, Double?) async -> BusinessBreakdownResult

/// `listedCodes`（呼び出し元は日経225構成銘柄集合を渡す想定。ファイル名は Stage 5 と揃えて汎用化して
/// いるが対象は上場全体ではない）の有報（直近 years 年ぶん）を走査し、未解決 or 再試行対象
/// （needs_review・xbrl_facts のバージョン不一致）のものを解決・格納する。`limit` は新規解決件数の
/// 上限（LLM 呼び出しを含み重いためバッチ実行用）。`explicitCodes` / `priorityCodes` は Stage 5 と同じ意味。
func runStage6Ingest(
    db: Database, listedCodes: Set<String>, years: Int,
    limit: Int?, explicitCodes: Set<String>? = nil, priorityCodes: Set<String> = [],
    logger: Logger? = nil, resolve: BusinessBreakdownResolveFn
) async throws -> Stage6IngestSummary {
    let sets = try await stage5Candidates(
        db: db, listedCodes: listedCodes, explicitCodes: explicitCodes, years: years, logger: logger)
    let baseCandidates = sets.keep

    var attempted = 0
    var stored = 0
    var notApplicable = 0
    var notApplicableGeographyOnly = 0
    var notApplicableSingleSegmentDisclosed = 0
    var notApplicableUnknown = 0
    var failed = 0
    var skipped = 0
    var unhealthyRetries = 0
    var missing: [(docID: String, code: String, submitDateTime: String)] = []
    var flaggedForReview: [(docID: String, code: String, submitDateTime: String)] = []
    var staleVersion: [(docID: String, code: String, submitDateTime: String)] = []

    for cand in baseCandidates {
        if unhealthyRetries >= Api.ingestDbUnhealthyRetryThreshold {
            logger?.error(
                "DB接続が不安定なため Stage 6 を中断します(リトライ\(unhealthyRetries)回・残り分類待ち書類あり)")
            break
        }
        let key = CompanyBreakdown.compositeID(docID: cand.docID, axis: breakdownAxisBusiness)
        let existing = try await withDbRetry(
            logger: logger, context: "docID=\(cand.docID)", onRetry: { unhealthyRetries += 1 }
        ) {
            try await CompanyBreakdown.find(key, on: db)
        }
        if existing == nil {
            missing.append(cand)
        } else if existing?.needsReview == true {
            flaggedForReview.append(cand)
        } else if let source = existing?.source, isVersionGatedBreakdownSource(source),
            existing?.cacheVersion != breakdownCacheVersion
        {
            staleVersion.append(cand)
        } else {
            skipped += 1
        }
    }
    let candidates = prioritized(
        missing + flaggedForReview + staleVersion, codeOf: \.code, priorityCodes: priorityCodes)
    // 分類フェーズと実処理フェーズでリトライ予算を分ける。
    unhealthyRetries = 0

    for cand in candidates {
        if unhealthyRetries >= Api.ingestDbUnhealthyRetryThreshold {
            logger?.error(
                "DB接続が不安定なため Stage 6 を中断します(リトライ\(unhealthyRetries)回・残り\(candidates.count - attempted)件は次回スケジュールで再試行)"
            )
            break
        }
        let key = CompanyBreakdown.compositeID(docID: cand.docID, axis: breakdownAxisBusiness)
        let existing = try await withDbRetry(
            logger: logger, context: "docID=\(cand.docID)", onRetry: { unhealthyRetries += 1 }
        ) {
            try await CompanyBreakdown.find(key, on: db)
        }
        if let row = existing, row.needsReview == false,
            !isVersionGatedBreakdownSource(row.source)
                || row.cacheVersion == breakdownCacheVersion
        {
            skipped += 1
            continue
        }
        if let lim = limit, attempted >= lim { break }
        attempted += 1

        let sales = try? await withDbRetry(
            logger: logger, context: "docID=\(cand.docID) 売上参照", onRetry: { unhealthyRetries += 1 }
        ) {
            try await consolidatedSalesForDoc(code: cand.code, docID: cand.docID, db: db)
        }

        switch await resolve(cand.docID, sales ?? nil) {
        case .resolved(let payload, let source, let contentHash, let audit):
            try await withDbRetry(
                logger: logger, context: "docID=\(cand.docID)", onRetry: { unhealthyRetries += 1 }
            ) {
                try await storeBreakdown(
                    existing: existing, docID: cand.docID, axis: breakdownAxisBusiness,
                    code: cand.code, submitDateTime: cand.submitDateTime, payload: payload,
                    source: source, contentHash: contentHash, cacheVersion: breakdownCacheVersion,
                    llmAudit: audit, db: db)
            }
            stored += 1
        case .notApplicable(let reason):
            notApplicable += 1
            switch reason {
            case breakdownNotApplicableGeographyOnly: notApplicableGeographyOnly += 1
            case breakdownNotApplicableSingleSegmentDisclosed: notApplicableSingleSegmentDisclosed += 1
            default: notApplicableUnknown += 1
            }
            // 既存行が実データ（source != not_applicable）を保持している場合は上書きしない。
            // 再試行（needsReview=true や cache_version 不一致）の対象になった行が、LLM 一時停止・
            // Stage 4 未計算等の一時的な理由で今回だけ notApplicable 判定された場合に、既存の
            // 正しいデータを破壊してしまうため（Opus監査で指摘、issue #132）。`.failed` と同じ
            // 「今回は進展なし、次回また再試行対象になる」扱いにする。
            if let existing, existing.source != breakdownSourceNotApplicable {
                logger?.warning(
                    "Stage 6: 既存の実データ行を notApplicable(\(reason)) で上書きしません(次回再試行): docID=\(cand.docID) code=\(cand.code)"
                )
            } else {
                // E/F は確信度の高い決定的判定のため needsReview=false（cache_version バンプでのみ
                // 再試行）。それ以外（unknown）は要調査のため needsReview=true にして再処理キューへ
                // 乗せる（通常巡回または `--codes` 指名 ingest で再分類できるようにする。issue #132）。
                let needsReview =
                    reason != breakdownNotApplicableGeographyOnly
                    && reason != breakdownNotApplicableSingleSegmentDisclosed
                let placeholder = BreakdownSnapshotPayload(
                    axis: breakdownAxisBusiness, denominator: 0, denominatorTag: "", rows: [],
                    sourceKind: breakdownSourceNotApplicable, needsReview: needsReview, warnings: [])
                try await withDbRetry(
                    logger: logger, context: "docID=\(cand.docID)", onRetry: { unhealthyRetries += 1 }
                ) {
                    try await storeBreakdown(
                        existing: existing, docID: cand.docID, axis: breakdownAxisBusiness,
                        code: cand.code, submitDateTime: cand.submitDateTime, payload: placeholder,
                        source: breakdownSourceNotApplicable, contentHash: "",
                        cacheVersion: breakdownCacheVersion, llmAudit: nil,
                        notApplicableReason: reason, db: db)
                }
            }
        case .failed:
            failed += 1
            logger?.warning("Stage 6 取り込み失敗: docID=\(cand.docID) code=\(cand.code)")
        }
    }

    // 保持窓を超えた既存行を purge する。分類・実処理フェーズとは別のリトライ予算を使う。
    unhealthyRetries = 0
    var purged = 0
    for docID in sets.purge {
        if unhealthyRetries >= Api.ingestDbUnhealthyRetryThreshold {
            logger?.error("DB接続が不安定なため Stage 6 purge を中断します(リトライ\(unhealthyRetries)回)")
            break
        }
        let key = CompanyBreakdown.compositeID(docID: docID, axis: breakdownAxisBusiness)
        let deleted = try await withDbRetry(
            logger: logger, context: "purge docID=\(docID)", onRetry: { unhealthyRetries += 1 }
        ) { () -> Bool in
            guard let row = try await CompanyBreakdown.find(key, on: db) else { return false }
            try await row.delete(on: db)
            return true
        }
        if deleted { purged += 1 }
    }

    return Stage6IngestSummary(
        attempted: attempted, stored: stored, notApplicable: notApplicable,
        notApplicableGeographyOnly: notApplicableGeographyOnly,
        notApplicableSingleSegmentDisclosed: notApplicableSingleSegmentDisclosed,
        notApplicableUnknown: notApplicableUnknown,
        failed: failed, skipped: skipped, purged: purged)
}

/// company_financials（Stage 4）から当該書類（docID）の連結売上高を引く。Stage 6 は自前で
/// XBRL から売上を再抽出せず、既に計算済みの Stage 4 の値を再利用する（重複ロジック回避）。
/// Stage 4 が当該コード・当該書類をまだ計算していない場合は nil。`BreakdownNormalizer` /
/// 両 LLM 正規化器はいずれも分母 nil（または 0）を許容せず即 nil を返す（=`.notApplicable`）ため、
/// Stage 4 未計算の間は当該書類が毎回 not_applicable になり、次回 ingest でも再試行され続ける
/// （EDINET 側は EdinetCacheStore のキャッシュヒットのため実害は小さいが、Stage 4 が先に
/// 計算済みであることが前提になる。デフォルトの `--stages` 実行順（4→4half→5→6）はこれを満たす）。
func consolidatedSalesForDoc(code: String, docID: String, db: Database) async throws -> Double? {
    guard let financials = try await CompanyFinancials.find(code, on: db) else { return nil }
    return financials.response.salesForDoc(docID)
}

/// 解決済み business 軸内訳を company_breakdowns へ書き込む（既存行があれば更新、無ければ作成）。
/// `notApplicableReason` は `source == breakdownSourceNotApplicable` の行にのみ渡す（issue #132）。
/// 省略時 nil（実データ行）。
func storeBreakdown(
    existing: CompanyBreakdown?, docID: String, axis: String, code: String,
    submitDateTime: String, payload: BreakdownSnapshotPayload, source: String, contentHash: String,
    cacheVersion: String, llmAudit: LLMBreakdownAuditPayload?, notApplicableReason: String? = nil,
    db: Database
) async throws {
    let applyFields: (CompanyBreakdown) -> Void = { row in
        row.code = code
        row.submitDateTime = submitDateTime
        row.payload = payload
        row.needsReview = payload.needsReview
        row.source = source
        row.contentHash = contentHash
        row.cacheVersion = cacheVersion
        row.llmAudit = llmAudit
        row.notApplicableReason = notApplicableReason
    }
    if let row = existing {
        applyFields(row)
        try await row.update(on: db)
    } else {
        let model = CompanyBreakdown(docID: docID, axis: axis)
        applyFields(model)
        try await createIdempotently(
            create: { try await model.create(on: db) },
            recover: {
                let key = CompanyBreakdown.compositeID(docID: docID, axis: axis)
                guard let recovered = try await CompanyBreakdown.find(key, on: db) else { return false }
                applyFields(recovered)
                try await recovered.update(on: db)
                return true
            }
        )
    }
}

// MARK: - servable/unservable 集計

/// `source`/`cache_version` のみを対象にした軽量射影（`payload` の JSONB を転送しない）。
/// company_breakdowns 全件の servable/unservable 集計用。
final class CompanyBreakdownSourceVersionOnly: Model, @unchecked Sendable {
    static let schema = CompanyBreakdown.schema

    @ID(custom: "id", generatedBy: .user)
    var id: String?

    @Field(key: "source")
    var source: String

    @Field(key: "cache_version")
    var cacheVersion: String

    init() {}
}

/// company_breakdowns 全件を read 可否（`isServableBreakdown`）で集計する。
/// ingest サマリログに DB 全体のカバレッジを添えるため、`payload` を転送しない軽量クエリで行う。
func countServableBreakdowns(db: Database) async throws -> (servable: Int, unservable: Int) {
    let rows = try await CompanyBreakdownSourceVersionOnly.query(on: db).all()
    let servable = rows.filter { isServableBreakdown(source: $0.source, cacheVersion: $0.cacheVersion) }
        .count
    return (servable, rows.count - servable)
}

// MARK: - read 経路（REST/MCP breakdown）

/// `loadStoredBreakdown` の結果3値。「行が無い/read不可」と「行はあるが business 軸が
/// 解決できなかった（reason付き）」を区別して呼び出し側（REST/MCP）へ伝える（issue #132）。
enum BreakdownLoadResult {
    /// 実データあり。公開契約 {code, doc_id, axis, breakdown} の JSON。
    case found([String: Any])
    /// 行はあるが business 軸が解決できなかった（`breakdownNotApplicable*` のいずれか）。
    case notApplicable(reason: String)
    /// 行が無い、または read 不可（バージョン床未満等）。
    case absent
}

/// 格納済み Stage 6 business 軸内訳を引いて公開契約 {code, doc_id, axis, breakdown} を返す。
/// axis は現状 "business" のみ受け付ける（geography は未配線のため行が無く、自然に absent になる）。
/// doc_id 指定時はその書類（当該 code のもの）、省略時は当該 code の最新有報（提出日時降順のうち read 可能な先頭）。
/// read 可否は `isServableBreakdown`（xbrl_facts/not_applicable はバージョン床、LLM 経由は常に可）。
/// 無い・read 不可なら `.absent`（呼び出し側は 404。ライブ解決へはフォールバックしない）。
func loadStoredBreakdown(
    code: String, docId: String?, axis: String, db: Database
) async throws -> BreakdownLoadResult {
    let code4 = String(code.prefix(4))
    guard !code4.isEmpty, code4.allSatisfy({ $0.isLetter || $0.isNumber }) else { return .absent }
    guard axis == breakdownAxisBusiness else { return .absent }

    let row: CompanyBreakdown?
    if let docId, !docId.isEmpty {
        let key = CompanyBreakdown.compositeID(docID: docId, axis: axis)
        let found = try await CompanyBreakdown.find(key, on: db)
        row = (found?.code == code4) ? found : nil
    } else {
        let candidates = try await CompanyBreakdown.query(on: db)
            .filter(\.$code == code4)
            .filter(\.$axis == axis)
            .sort(\.$submitDateTime, .descending)
            .all()
        row = candidates.first { isServableBreakdown(source: $0.source, cacheVersion: $0.cacheVersion) }
    }

    guard let row, isServableBreakdown(source: row.source, cacheVersion: row.cacheVersion),
        let docID = row.id?.components(separatedBy: "#").first
    else { return .absent }

    if let reason = row.notApplicableReason {
        return .notApplicable(reason: reason)
    }

    var result: [String: Any] = [
        "code": code4,
        "doc_id": docID,
        "axis": row.axis,
        "breakdown": row.payload.jsonObject(),
    ]
    // LLM 経由の行のみ（xbrl_facts 経由は llmAudit が無い）。denominator_tag が
    // "income_statement.sales" 以外（例: "llm_table_subtotal"）のとき、実際の指標名を
    // notes から確認できるようにする（issue #105 のprofit指標区別ギャップ対応）。
    if let llmAudit = row.llmAudit {
        result["llm_audit"] = llmAudit.jsonObject()
    }
    return .found(result)
}
