// 内訳取り込み: 上場企業の有報について軸別（business / geography 等）の内訳を解決し
// company_breakdowns へ upsert する。解決は BlueTickerCore のファサード
// （resolveBusinessBreakdown / resolveGeographyBreakdown）に委譲し、ここでは対象選定・
// staleness 判定・DB upsert のみを担う（ネットワーク非依存でテスト可能）。
// 呼び出し元（FactsIngest）が business → geography の順で本関数を呼ぶ。
// REST/MCP の read（loadStoredBreakdown）は business / geography の両軸を公開する
// （2026-07-27、品質ゲート＝最新有報の needs_review=true・あいまい失敗0を確認のうえ解禁）。
//
// 対象母集団は呼び出し元が `listedCodes` に渡す集合。business/geography は上場全体、
// 決定論指標軸は日経225。日経225（`priorityCodes`）は処理順の先頭寄せにも使う。
// `--codes` 指定時はその集合に絞る。
//
// 候補選定ロジック自体は有報セクション取り込み（`filingSectionCandidates`、「対象 × 有報(120) × 直近 years 件」）を再利用する
// （事業別内訳は有報と同じ書類集合から取れるため）。年数（`years`）は呼び出し元が有報セクション取り込みと同じ
// `filingSectionsIngestYears` を渡す想定（内訳取り込み専用の別値は持たない）。
//
// staleness 判定は有報セクション取り込みと異なる（docs/breakdown.md）。
// - version-gated な source（決定論 + LLM）: cache_version が現行と不一致なら再計算する。
//   clean な segment_info_llm がバンプを無視すると誤 profit が残るため、LLM も対象。
// - 決定論の needs_review=true だけでは再試行しない（同じ入力では結果が変わらないフラグが
//   limit を埋め続けるため）。LLM の needs_review=true は現行版でも再試行する。

import BlueTickerCore
import Fluent
import Foundation
import Logging

/// 内訳取り込み結果のサマリ。
public struct BreakdownIngestSummary: Sendable, Equatable {
    /// 解決を試みた書類数（skip を除く）。
    public let attempted: Int
    /// 解決・格納に成功した書類数。
    public let stored: Int
    /// 書類の取得・抽出自体は成功したが当該軸の内訳が解決できなかった書類数（失敗ではない）。
    public let notApplicable: Int
    /// notApplicable の内訳（issue #130、E/F判定の検知結果明示化）。
    /// E: 報告セグメントが地域別のみで business 軸への swap が見つからなかった書類数。
    public let notApplicableGeographyOnly: Int
    /// F: 単一セグメントのため報告セグメント開示自体が省略されていた書類数。
    public let notApplicableSingleSegmentDisclosed: Int
    /// 上記いずれにも該当しない・原因未特定の書類数（要調査）。
    /// geography の正当欠測（`not_found`）はここに含めない。
    public let notApplicableUnknown: Int
    /// 取得・抽出失敗でスキップした書類数。
    public let failed: Int
    /// 既に現行版・needs_review=false で解決済みのためスキップした書類数。
    public let skipped: Int
    /// 保持窓（直近 years 件）を超えたため削除した既存行数。
    public let purged: Int
}

/// docID を受けて軸別内訳の解決結果を返す関数。
/// 本番は `context.resolveBusinessBreakdown` 等、テストはフェイクを注入する。
/// 分母（売上・employees・rd）は resolve 側が同一 XBRL パスで直接解決する（#9 / #10b）。
public typealias BreakdownResolveFn = @Sendable (String) async -> BreakdownResolveResult

/// `listedCodes`（呼び出し元は上場企業集合。`--codes` 時はその部分集合）の有報（直近 years 年ぶん）を
/// 走査し、未解決 or 再試行対象（needs_review・xbrl_facts のバージョン不一致）のものを解決・格納する。
/// `limit` は新規解決件数の上限（LLM 呼び出しを含み重いためバッチ実行用。軸ごとの呼び出しで独立に適用）。
/// `explicitCodes` / `priorityCodes` は 有報セクション取り込み と同じ意味（後者は処理順のみ）。
/// `axis` は `isSupportedBreakdownAxis` が受け付ける軸。
/// `cachedDocIDs` はローカル XBRL 展開済みの書類。処理順は各社の最新有報 → 前年以降。同一年次内は
/// 日経225 → キャッシュ済み → 欠測/要再試行/版ずれのラウンドロビン。
func runBreakdownIngest(
    db: Database, listedCodes: Set<String>, years: Int,
    limit: Int?, explicitCodes: Set<String>? = nil, priorityCodes: Set<String> = [],
    cachedDocIDs: Set<String> = [],
    axis: String = breakdownAxisBusiness,
    candidateSets: FilingSectionCandidateSets? = nil,
    logger: Logger? = nil,
    resolve: BreakdownResolveFn
) async throws -> BreakdownIngestSummary {
    let currentCacheVersion = breakdownCacheVersion(forAxis: axis)
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
    var notApplicableGeographyOnly = 0
    var notApplicableSingleSegmentDisclosed = 0
    var notApplicableUnknown = 0
    var failed = 0
    var skipped = 0
    var unhealthyRetries = 0
    var missing: [FilingDocCandidate] = []
    var flaggedForReview: [FilingDocCandidate] = []
    var staleVersion: [FilingDocCandidate] = []

    // 分類は payload を含まない1クエリ。候補ごとに find すると上場全体×6年で
    // Neon 往復が数万回になり、実処理より分類がステージ timeout を食う。
    let classifyRows = try await withDbRetry(
        logger: logger, context: "内訳取り込み(\(axis)) 分類", onRetry: { unhealthyRetries += 1 }
    ) {
        try await CompanyBreakdownSourceVersionOnly.query(on: db)
            .filter(\.$axis == axis)
            .all()
    }
    let classifyIndex = ingestIndexByID(classifyRows) { $0.id }

    for cand in baseCandidates {
        let key = CompanyBreakdown.compositeID(docID: cand.docID, axis: axis)
        guard let existing = classifyIndex[key] else {
            missing.append(cand)
            continue
        }
        if isVersionGatedBreakdownSource(existing.source) {
            if existing.cacheVersion != currentCacheVersion {
                staleVersion.append(cand)
            } else {
                skipped += 1
            }
        } else if existing.needsReview {
            flaggedForReview.append(cand)
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
                "DB接続が不安定なため 内訳取り込み(\(axis)) を中断します(リトライ\(unhealthyRetries)回・残り\(candidates.count - attempted)件は次回スケジュールで再試行)"
            )
            break
        }
        let key = CompanyBreakdown.compositeID(docID: cand.docID, axis: axis)
        let existing = try await withDbRetry(
            logger: logger, context: "docID=\(cand.docID)", onRetry: { unhealthyRetries += 1 }
        ) {
            try await CompanyBreakdown.find(key, on: db)
        }
        if let row = existing {
            let versionGated = isVersionGatedBreakdownSource(row.source)
            if versionGated, row.cacheVersion == currentCacheVersion {
                skipped += 1
                continue
            }
            if !versionGated, row.needsReview == false {
                skipped += 1
                continue
            }
        }
        if let lim = limit, attempted >= lim { break }
        attempted += 1

        let resolveResult = await resolve(cand.docID)

        switch resolveResult {
        case .resolved(let payload, let source, let contentHash, let audit):
            try await withDbRetry(
                logger: logger, context: "docID=\(cand.docID)", onRetry: { unhealthyRetries += 1 }
            ) {
                try await storeBreakdown(
                    existing: existing, docID: cand.docID, axis: axis,
                    code: cand.code, submitDateTime: cand.submitDateTime, payload: payload,
                    source: source, contentHash: contentHash, cacheVersion: currentCacheVersion,
                    llmAudit: audit, db: db)
            }
            stored += 1
        case .notApplicable(let reason):
            notApplicable += 1
            switch reason {
            case breakdownNotApplicableGeographyOnly: notApplicableGeographyOnly += 1
            case breakdownNotApplicableSingleSegmentDisclosed: notApplicableSingleSegmentDisclosed += 1
            case breakdownNotApplicableNotFound: break
            default: notApplicableUnknown += 1
            }
            // 既存行が実データ（source != not_applicable）を保持している場合は上書きしない。
            // 再試行（needsReview=true や cache_version 不一致）の対象になった行が、LLM 一時停止等の
            // 一時的な理由で今回だけ notApplicable 判定された場合に、既存の正しいデータを
            // 破壊してしまうため（Opus監査で指摘、issue #132）。`.failed` と同じ
            // 「今回は進展なし、次回また再試行対象になる」扱いにする。
            if let existing, existing.source != breakdownSourceNotApplicable {
                logger?.warning(
                    "内訳取り込み(\(axis)): 既存の実データ行を notApplicable(\(reason)) で上書きしません(次回再試行): docID=\(cand.docID) code=\(cand.code)"
                )
            } else {
                // E/F / geography not_found は決定的判定のため needsReview=false。
                // unknown 等は要調査のため needsReview=true で残す（再計算は cache_version バンプ）。
                let needsReview = !isDeterministicBreakdownNotApplicableReason(reason)
                let placeholder = BreakdownSnapshotPayload(
                    axis: axis, denominator: 0, denominatorTag: "", rows: [],
                    sourceKind: breakdownSourceNotApplicable, needsReview: needsReview, warnings: [])
                try await withDbRetry(
                    logger: logger, context: "docID=\(cand.docID)", onRetry: { unhealthyRetries += 1 }
                ) {
                    try await storeBreakdown(
                        existing: existing, docID: cand.docID, axis: axis,
                        code: cand.code, submitDateTime: cand.submitDateTime, payload: placeholder,
                        source: breakdownSourceNotApplicable, contentHash: "",
                        cacheVersion: currentCacheVersion, llmAudit: nil,
                        notApplicableReason: reason, db: db)
                }
            }
        case .failed:
            failed += 1
            logger?.warning("内訳取り込み(\(axis)) 取り込み失敗: docID=\(cand.docID) code=\(cand.code)")
        }
    }

    // 保持窓を超えた既存行を purge する。分類・実処理フェーズとは別のリトライ予算を使う。
    unhealthyRetries = 0
    var purged = 0
    if !sets.purge.isEmpty {
        let purgeDocIDs = Set(sets.purge)
        purged = try await withDbRetry(
            logger: logger, context: "内訳取り込み(\(axis)) purge", onRetry: { unhealthyRetries += 1 }
        ) {
            let n = try await CompanyBreakdown.query(on: db)
                .filter(\.$axis == axis)
                .filter(\.$docID ~~ purgeDocIDs)
                .count()
            if n > 0 {
                try await CompanyBreakdown.query(on: db)
                    .filter(\.$axis == axis)
                    .filter(\.$docID ~~ purgeDocIDs)
                    .delete()
            }
            return n
        }
    }

    return BreakdownIngestSummary(
        attempted: attempted, stored: stored, notApplicable: notApplicable,
        notApplicableGeographyOnly: notApplicableGeographyOnly,
        notApplicableSingleSegmentDisclosed: notApplicableSingleSegmentDisclosed,
        notApplicableUnknown: notApplicableUnknown,
        failed: failed, skipped: skipped, purged: purged)
}

/// 解決済み内訳を company_breakdowns へ書き込む（既存行があれば更新、無ければ作成）。
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

/// `source`/`cache_version`/`axis`/`needs_review` を対象にした軽量射影（`payload` の JSONB を転送しない）。
/// 内訳取り込みの分類と servable/unservable 集計用。
final class CompanyBreakdownSourceVersionOnly: Model, @unchecked Sendable {
    static let schema = CompanyBreakdown.schema

    @ID(custom: "id", generatedBy: .user)
    var id: String?

    @Field(key: "source")
    var source: String

    @Field(key: "cache_version")
    var cacheVersion: String

    @Field(key: "axis")
    var axis: String

    @Field(key: "needs_review")
    var needsReview: Bool

    init() {}
}

/// company_breakdowns 全件を read 可否（`isServableBreakdown`）で集計する。
/// ingest サマリログに DB 全体のカバレッジを添えるため、`payload` を転送しない軽量クエリで行う。
func countServableBreakdowns(db: Database) async throws -> (servable: Int, unservable: Int) {
    let rows = try await CompanyBreakdownSourceVersionOnly.query(on: db).all()
    let servable = rows.filter {
        isServableBreakdown(source: $0.source, cacheVersion: $0.cacheVersion, axis: $0.axis)
    }.count
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

/// 格納済み 内訳取り込み 内訳を引いて公開契約 {code, doc_id, axis, breakdown} を返す。
/// axis は `isSupportedBreakdownAxis` が受け付ける軸を受け付ける
/// （geography は 2026-07-27、品質ゲート＝最新有報の needs_review=true・あいまい失敗0を確認のうえ
/// 解禁。employees/research_and_development/goodwill は決定論のみで LLM 非依存だが
/// REST/MCP への実際の公開可否は別途都度確認する。未知の軸は absent）。
/// doc_id 指定時はその書類（当該 code のもの）、省略時は当該 code の最新会社有報
/// （提出日時降順のうち read 可能・会社開示府令の先頭）。特定有価証券府令(030)は選ばない。
/// read 可否は `isServableBreakdown`（決定論・LLM とも cache_version の床でゲート）。
/// 無い・read 不可・府令対象外なら `.absent`（呼び出し側は 404。ライブ解決へはフォールバックしない）。
func loadStoredBreakdown(
    code: String, docId: String?, axis: String, db: Database
) async throws -> BreakdownLoadResult {
    let code4 = String(code.prefix(4))
    guard !code4.isEmpty, code4.allSatisfy({ $0.isLetter || $0.isNumber }) else { return .absent }
    guard isSupportedBreakdownAxis(axis) else { return .absent }

    let row: CompanyBreakdown?
    if let docId, !docId.isEmpty {
        guard try await isCompanyDisclosureDoc(docID: docId, db: db) else { return .absent }
        let key = CompanyBreakdown.compositeID(docID: docId, axis: axis)
        let found = try await CompanyBreakdown.find(key, on: db)
        row = (found?.code == code4) ? found : nil
    } else {
        let candidates = try await CompanyBreakdown.query(on: db)
            .filter(\.$code == code4)
            .filter(\.$axis == axis)
            .sort(\.$submitDateTime, .descending)
            .all()
        let companyDocIDs = try await companyDisclosureDocIDs(
            among: candidates.map(\.docID), db: db)
        row = candidates.first {
            isServableBreakdown(source: $0.source, cacheVersion: $0.cacheVersion, axis: axis)
                && companyDocIDs.contains($0.docID)
        }
    }

    guard let row, isServableBreakdown(source: row.source, cacheVersion: row.cacheVersion, axis: axis),
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
