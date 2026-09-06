// 銘柄 Overview 取り込み: 上場企業の直近有報から「事業の内容」を材料に短い会社説明を生成し
// company_overviews へ upsert する。1社=1行（icons と同じ。過去書類の履歴保持・purgeは不要）。
// 生成は LLM（`source=llm`）。入力が空で applicable=false の行は `not_applicable`。
// `ok=false` は needs_review として再試行する。最新有報の doc_id が変わったら上書きする。
// cache_version バンプだけでは LLM 成功行は再生成しない（有報が同じなら skip）。
// 決定論の not_applicable だけは版ずれで再実行する。

import BlueTickerCore
import Fluent
import Foundation
import Logging

/// 銘柄 Overview 取り込み結果のサマリ。
public struct OverviewIngestSummary: Sendable, Equatable {
    /// 生成を試みた会社数（skip を除く）。
    public let attempted: Int
    /// 生成・格納に成功した会社数（実データ行。`ok=false` の needs_review も含む）。
    public let stored: Int
    /// 書類取得失敗でスキップした会社数。
    public let failed: Int
    /// 入力空など設計通りの対象外（プレースホルダ行を格納）。
    public let notApplicable: Int
    /// 同一 doc_id・要再試行なしのためスキップした会社数（LLM 成功行は cache_version が古くても含む）。
    public let skipped: Int
}

/// docID・code を受けて Overview 生成結果を返す。
/// 本番は `context.generateCompanyOverview`、テストはフェイクを注入する。
public typealias CompanyOverviewGenerating =
    @Sendable (String, String) async -> CompanyOverviewResolveResult

/// 上場企業の直近有報1件ずつを走査し、未生成 / 最新 doc 変更 / needs_review /
/// 版ずれの not_applicable の Overview を生成・格納する。
/// `explicitCodes` / `priorityCodes` / `cachedDocIDs` は icons と同じ意味。
func runOverviewIngest(
    db: Database, listedCodes: Set<String>, limit: Int?, explicitCodes: Set<String>? = nil,
    priorityCodes: Set<String> = [], cachedDocIDs: Set<String> = [],
    logger: Logger? = nil, generate: CompanyOverviewGenerating
) async throws -> OverviewIngestSummary {
    let baseCandidates = try await latestAnnualReportPerCompany(
        db: db, listedCodes: listedCodes, explicitCodes: explicitCodes, logger: logger)

    var attempted = 0
    var stored = 0
    var failed = 0
    var notApplicable = 0
    var skipped = 0
    var unhealthyRetries = 0
    var missing: [(docID: String, code: String, submitDateTime: String)] = []
    var flaggedForReview: [(docID: String, code: String, submitDateTime: String)] = []
    var staleDoc: [(docID: String, code: String, submitDateTime: String)] = []
    var staleNotApplicable: [(docID: String, code: String, submitDateTime: String)] = []

    let classifyRows = try await withDbRetry(
        logger: logger, context: "銘柄 Overview 取り込み 分類", onRetry: { unhealthyRetries += 1 }
    ) {
        try await CompanyOverviewClassifyRow.query(on: db).all()
    }
    let classifyIndex = ingestIndexByID(classifyRows) { $0.id }

    for cand in baseCandidates {
        guard let existing = classifyIndex[cand.code] else {
            missing.append(cand)
            continue
        }
        if existing.docID != cand.docID {
            staleDoc.append(cand)
        } else if existing.needsReview {
            flaggedForReview.append(cand)
        } else if existing.source == companyOverviewSourceNotApplicable,
            existing.cacheVersion != companyOverviewCacheVersion
        {
            staleNotApplicable.append(cand)
        } else {
            skipped += 1
        }
    }
    let candidates = ingestOrdered(
        interleaved([missing, flaggedForReview, staleDoc, staleNotApplicable]),
        docIDOf: \.docID, codeOf: \.code, cachedDocIDs: cachedDocIDs, priorityCodes: priorityCodes)
    unhealthyRetries = 0

    for cand in candidates {
        if unhealthyRetries >= Api.ingestDbUnhealthyRetryThreshold {
            logger?.error(
                "DB接続が不安定なため 銘柄 Overview 取り込み を中断します(リトライ\(unhealthyRetries)回・残り\(candidates.count - attempted)件は次回スケジュールで再試行)"
            )
            break
        }
        let existing = try await withDbRetry(
            logger: logger, context: "code=\(cand.code)", onRetry: { unhealthyRetries += 1 }
        ) {
            try await CompanyOverview.find(cand.code, on: db)
        }
        if let row = existing, row.docID == cand.docID, !row.needsReview {
            let staleNotApplicable =
                row.source == companyOverviewSourceNotApplicable
                && row.cacheVersion != companyOverviewCacheVersion
            if !staleNotApplicable {
                skipped += 1
                continue
            }
        }
        if let lim = limit, attempted >= lim { break }
        attempted += 1
        switch await generate(cand.docID, cand.code) {
        case .failed:
            failed += 1
            logger?.warning(
                "銘柄 Overview 取り込み失敗: docID=\(cand.docID) code=\(cand.code)")
            continue
        case .generated(let draft, let sourceText):
            try await withDbRetry(
                logger: logger, context: "code=\(cand.code)", onRetry: { unhealthyRetries += 1 }
            ) {
                try await storeCompanyOverview(
                    existing: try await CompanyOverview.find(cand.code, on: db),
                    code: cand.code, docID: cand.docID, submitDateTime: cand.submitDateTime,
                    draft: draft, sourceText: sourceText, db: db)
            }
            if !draft.applicable, draft.ok {
                notApplicable += 1
            } else {
                stored += 1
            }
        }
    }

    return OverviewIngestSummary(
        attempted: attempted, stored: stored, failed: failed, notApplicable: notApplicable,
        skipped: skipped)
}

/// 生成済み Overview を company_overviews へ書き込む（既存行があれば更新、無ければ作成）。
func storeCompanyOverview(
    existing: CompanyOverview?, code: String, docID: String, submitDateTime: String,
    draft: CompanyOverviewDraft, sourceText: String, db: Database
) async throws {
    let payload = CompanyOverviewPayload(draft: draft)
    let hash = companyOverviewContentHash(sourceText)
    let applyFields: (CompanyOverview) -> Void = { row in
        row.docID = docID
        row.submitDateTime = submitDateTime
        row.payload = payload
        row.needsReview = payload.needsReview
        row.source = payload.source
        row.contentHash = hash
        row.cacheVersion = companyOverviewCacheVersion
        row.notApplicableReason = payload.notApplicableReason
    }
    if let row = existing {
        applyFields(row)
        try await row.update(on: db)
    } else {
        let model = CompanyOverview(
            code: code, docID: docID, submitDateTime: submitDateTime, payload: payload,
            contentHash: hash)
        try await createIdempotently(
            create: { try await model.create(on: db) },
            recover: {
                guard let recovered = try await CompanyOverview.find(code, on: db) else { return false }
                applyFields(recovered)
                try await recovered.update(on: db)
                return true
            }
        )
    }
}

/// 分類の N+1 find 回避用。payload JSONB は転送しない。
final class CompanyOverviewClassifyRow: Model, @unchecked Sendable {
    static let schema = CompanyOverview.schema

    @ID(custom: "code", generatedBy: .user)
    var id: String?

    @Field(key: "doc_id")
    var docID: String

    @Field(key: "cache_version")
    var cacheVersion: String

    @Field(key: "needs_review")
    var needsReview: Bool

    @Field(key: "source")
    var source: String

    init() {}
}

// MARK: - read 経路（REST overview）

/// 格納済み Overview を code で引く。read 床以上かつ applicable・ok な本文があるときだけ返す。
/// 無い・床未満・対象外・生成失敗は nil（呼び出し側 404。ライブ生成へはフォールバックしない）。
func loadStoredOverview(code: String, db: Database) async throws -> [String: Any]? {
    guard let row = try await CompanyOverview.find(code, on: db),
        isServableCompanyOverviewCacheVersion(row.cacheVersion),
        row.payload.ok,
        row.payload.applicable
    else { return nil }
    let text = row.payload.overview.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    return companyOverviewServeJSON(code: row.id ?? code, overview: text, docID: row.docID)
}
