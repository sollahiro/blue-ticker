// 内訳取り込み: 上場企業の有報について軸別（product_service / geography 等）の内訳を解決し
// company_breakdowns へ upsert する。解決は BlueTickerCore のファサード
// （resolveBusinessBreakdown / resolveGeographyBreakdown）に委譲し、ここでは対象選定・
// staleness 判定・DB upsert のみを担う（ネットワーク非依存でテスト可能）。
// 呼び出し元（FactsIngest）が product_service → geography の順で本関数を呼ぶ。
// REST/MCP の read（loadStoredBreakdown）は product_service / geography の両軸を公開する
// （2026-07-27、品質ゲート＝最新有報の needs_review=true・あいまい失敗0を確認のうえ解禁）。
//
// 対象母集団は呼び出し元が `listedCodes` に渡す集合。全軸とも上場全体
// （2026-09: employees/rd/goodwill・報告セグメント別指標軸も日経225限定を廃止して拡大）。
// 日経225（`priorityCodes`）は処理順の先頭寄せに使う。`--codes` 指定時はその集合に絞る。
//
// 候補選定ロジック自体は有報セクション取り込み（`filingSectionCandidates`、「対象 × 有報(120) × 直近 years 件」）を再利用する
// （事業別内訳は有報と同じ書類集合から取れるため）。年数（`years`）は呼び出し元が有報セクション取り込みと同じ
// `filingSectionsIngestYears` を渡す想定（内訳取り込み専用の別値は持たない）。
//
// staleness 判定は有報セクション取り込みと異なる（docs/breakdown.md）。
// - version-gated な source（決定論 + LLM）: cache_version が現行と不一致なら再計算する。
//   clean な segment_info_llm がバンプを無視すると誤 profit が残るため、LLM も対象。
// - 決定論の needs_review=true だけでは再試行しない（同じ入力では結果が変わらないフラグが
//   limit を埋め続けるため）。
// - LLM の needs_review=true は現行版でも再試行する（一時失敗の再キュー）。

import BltStoreCore
import BlueTickerCore
import FluentKit
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
    /// E: 報告セグメントが地域別のみで product_service 軸への swap が見つからなかった書類数。
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
    axis: String = breakdownAxisProductService,
    candidateSets: FilingSectionCandidateSets? = nil,
    forceDocIDs: Set<String> = [],
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
    let classifyDocIDs = Set(baseCandidates.map(\.docID))
    let classifyRows = try await withDbRetry(
        logger: logger, context: "内訳取り込み(\(axis)) 分類", onRetry: { unhealthyRetries += 1 }
    ) {
        try await breakdownClassifyRows(db: db, axis: axis, docIDs: classifyDocIDs)
    }
    let classifyIndex = ingestIndexByID(classifyRows) { $0.id }
    // Jev 再試行の判定に payload.warnings が要る。分類クエリは payload を載せないので、
    // needs_review の interest_bearing_debt 行だけ後から warnings を引く。
    let jevRetryable = try await jevRetryableBreakdownIDs(
        axis: axis, classifyRows: classifyRows, db: db)

    for cand in baseCandidates {
        if forceDocIDs.contains(cand.docID) {
            missing.append(cand)
            continue
        }
        let key = CompanyBreakdown.compositeID(docID: cand.docID, axis: axis)
        guard let existing = classifyIndex[key] else {
            missing.append(cand)
            continue
        }
        if isVersionGatedBreakdownSource(existing.source) {
            if existing.cacheVersion != currentCacheVersion {
                staleVersion.append(cand)
            } else if isLLMBreakdownSource(existing.source), existing.needsReview {
                // LLM は現行版でも needs_review で再試行（決定論とは非対称）。
                flaggedForReview.append(cand)
            } else if jevRetryable.contains(key) {
                // interest_bearing_debt は xbrl_facts でも、Jev が分類・近似重複で止まった行だけ再試行。
                flaggedForReview.append(cand)
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
        // interest_bearing_debt の Jev 再試行なら何回目か（0 は再試行でない）。
        var ibdJevRetryAttempt = 0
        if !forceDocIDs.contains(cand.docID), let row = existing {
            let versionGated = isVersionGatedBreakdownSource(row.source)
            if versionGated, row.cacheVersion == currentCacheVersion {
                // 現行版の決定論は skip。LLM の needs_review は再試行する。
                // content_hash は見ない。clean な geography_llm は --codes でも skip する。
                // 経路の差し替え（旧 LLM 行→Jev 等）は対象行 DELETE（または --doc-ids）が必要。バンプしない。
                // interest_bearing_debt は Jev が分類・近似重複で止まった行だけ現行版でも再試行。
                let priorAttempts = ibdJevRetryAttempts(row.llmAudit)
                let jevRetry = isJevRetryableBreakdown(
                    axis: axis, needsReview: row.needsReview, warnings: row.payload.warnings,
                    attempts: priorAttempts)
                if !(isLLMBreakdownSource(row.source) && row.needsReview), !jevRetry {
                    skipped += 1
                    continue
                }
                if jevRetry { ibdJevRetryAttempt = priorAttempts + 1 }
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
            let storedAudit = stampingIBDJevRetryAttempt(audit, attempt: ibdJevRetryAttempt)
            try await withDbRetry(
                logger: logger, context: "docID=\(cand.docID)", onRetry: { unhealthyRetries += 1 }
            ) {
                try await storeBreakdown(
                    existing: try await CompanyBreakdown.find(key, on: db),
                    docID: cand.docID, axis: axis,
                    code: cand.code, submitDateTime: cand.submitDateTime, payload: payload,
                    source: source, contentHash: contentHash, cacheVersion: currentCacheVersion,
                    llmAudit: storedAudit, db: db)
            }
            stored += 1
            await logXbrlOverlayRegressionIfNeeded(
                warnings: payload.warnings, code: cand.code, docID: cand.docID, db: db,
                logger: logger)
        case .notApplicable(let reason, let audit):
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
                // Jev が確率不足・欠測・文クラスの衝突で適用しなかったときは、決定的 reason でも
                // needs_review を立て、判断を llm_audit に残す。
                let withheld = audit?.jev?.needsReview == true
                let needsReview = withheld || !isDeterministicBreakdownNotApplicableReason(reason)
                let placeholder = BreakdownSnapshotPayload(
                    axis: axis, denominator: 0, denominatorTag: "", rows: [],
                    sourceKind: breakdownSourceNotApplicable, needsReview: needsReview, warnings: [])
                try await withDbRetry(
                    logger: logger, context: "docID=\(cand.docID)", onRetry: { unhealthyRetries += 1 }
                ) {
                    try await storeBreakdown(
                        existing: try await CompanyBreakdown.find(key, on: db),
                        docID: cand.docID, axis: axis,
                        code: cand.code, submitDateTime: cand.submitDateTime, payload: placeholder,
                        source: breakdownSourceNotApplicable, contentHash: "",
                        cacheVersion: currentCacheVersion, llmAudit: audit,
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
        row.llmAudit = llmAudit?.stamped(code: code)
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

    /// 候補 `doc_id = ANY(...)` で分類を絞るために載せる。payload は持たない。
    @Field(key: "doc_id")
    var docID: String

    init() {}
}

/// 当該軸の分類行。`docIDs` が空ならクエリしない。payload JSON は読まない。
func breakdownClassifyRows(
    db: Database, axis: String, docIDs: Set<String>
) async throws -> [CompanyBreakdownSourceVersionOnly] {
    guard !docIDs.isEmpty else { return [] }
    return try await CompanyBreakdownSourceVersionOnly.query(on: db)
        .filter(\.$axis == axis)
        .filter(\.$docID ~~ Array(docIDs))
        .all()
}

/// company_breakdowns 全件を read 可否（`isServableBreakdown`）で集計する。
/// ingest サマリログに DB 全体のカバレッジを添えるため、`payload` を転送せず
/// `COUNT(*) GROUP BY source, cache_version, axis` してから既存の `isServableBreakdown` を当てる。
func countServableBreakdowns(db: Database) async throws -> (servable: Int, unservable: Int) {
    let groups = try await sqlGroupedSourceVersionCounts(
        db: db, schema: CompanyBreakdown.schema, groupColumn: "axis")
    return servableCounts(from: groups) { source, version, axis in
        isServableBreakdown(source: source, cacheVersion: version, axis: axis)
    }
}

// MARK: - read 経路（REST/MCP breakdown）

/// 分類フェーズ用。needs_review の interest_bearing_debt 行のうち、Jev 再試行対象の合成 ID。
/// 他軸・coverage だけの needs_review は空（payload を転送しない）。
private func jevRetryableBreakdownIDs(
    axis: String, classifyRows: [CompanyBreakdownSourceVersionOnly], db: Database
) async throws -> Set<String> {
    guard axis == breakdownAxisInterestBearingDebt else { return [] }
    let ids = classifyRows.compactMap { row -> String? in
        guard row.needsReview, let id = row.id else { return nil }
        return id
    }
    guard !ids.isEmpty else { return [] }
    let rows = try await CompanyBreakdown.query(on: db)
        .filter(\.$id ~~ ids)
        .all()
    return Set(rows.compactMap { row -> String? in
        guard let id = row.id,
            isJevRetryableBreakdown(
                axis: axis, needsReview: row.needsReview, warnings: row.payload.warnings,
                attempts: ibdJevRetryAttempts(row.llmAudit))
        else { return nil }
        return id
    })
}

