// 業種 KPI 取り込み: 上場企業の有報から銀行 XBRL 数値 KPI を抽出し industry_kpi_facts へ upsert する。
// 抽出は BlueTickerCore のファサードに委譲し、ここでは対象選定・staleness・DB upsert だけを担う。
// 候補選定は filingSectionCandidates を再利用する。
//
// `--stages` の既定からは外す（relations と同じ。本番 drain に乗せない。Mac で明示指定）。
// 対象会社は「提出者業種が銀行業」または許可リストまたは statements の銀行様式 IS /
// 預金マーカーに先に絞る（`industryKpiBankCandidateCodes`）。上場全体 ~2 万件に空行を書かない。
// 絞った後でも XBRL 判定で非銀行だった書類は not_applicable プレースホルダへ置換し、
// 現行 cache_version なら skip する。

import BltStoreCore
import BlueTickerCore
import FluentKit
import Foundation
import Logging
import SQLKit

public struct IndustryKpiIngestSummary: Sendable, Equatable {
    public let attempted: Int
    public let stored: Int
    public let notApplicable: Int
    public let failed: Int
    public let skipped: Int
    public let purged: Int
}

public typealias IndustryKpiResolveFn = @Sendable (String, String) async -> IndustryKpiResolveResult

func runIndustryKpiIngest(
    db: Database, listedCodes: Set<String>, years: Int,
    limit: Int?, explicitCodes: Set<String>? = nil, priorityCodes: Set<String> = [],
    cachedDocIDs: Set<String> = [],
    industryGroup: String = industryKpiGroupBank,
    candidateSets: FilingSectionCandidateSets? = nil,
    forceDocIDs: Set<String> = [],
    logger: Logger? = nil, resolve: IndustryKpiResolveFn
) async throws -> IndustryKpiIngestSummary {
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
    var staleVersion: [FilingDocCandidate] = []

    let classifyDocIDs = Set(baseCandidates.map(\.docID))
    let classifyRows = try await withDbRetry(
        logger: logger, context: "業種KPI取り込み(\(industryGroup)) 分類",
        onRetry: { unhealthyRetries += 1 }
    ) {
        try await industryKpiClassifyRows(
            db: db, industryGroup: industryGroup, docIDs: classifyDocIDs)
    }
    let classifyIndex = ingestIndexByID(classifyRows) { $0.id }

    for cand in baseCandidates {
        if forceDocIDs.contains(cand.docID) {
            missing.append(cand)
            continue
        }
        let key = IndustryKpiFact.compositeID(docID: cand.docID, industryGroup: industryGroup)
        guard let existing = classifyIndex[key] else {
            missing.append(cand)
            continue
        }
        if existing.cacheVersion != industryKpiCacheVersion {
            staleVersion.append(cand)
        } else {
            skipped += 1
        }
    }
    let candidates = ingestOrderedByYearRank(
        [missing, staleVersion],
        docIDOf: \.docID, codeOf: \.code, yearRankOf: \.yearRank,
        cachedDocIDs: cachedDocIDs, priorityCodes: priorityCodes)
    unhealthyRetries = 0

    for cand in candidates {
        if unhealthyRetries >= Api.ingestDbUnhealthyRetryThreshold {
            logger?.error(
                "DB接続が不安定なため 業種KPI取り込み(\(industryGroup)) を中断します(リトライ\(unhealthyRetries)回・残り\(candidates.count - attempted)件は次回スケジュールで再試行)"
            )
            break
        }
        let key = IndustryKpiFact.compositeID(docID: cand.docID, industryGroup: industryGroup)
        if let lim = limit, attempted >= lim { break }
        attempted += 1

        switch await resolve(cand.docID, cand.code) {
        case .resolved(let payload, let source, let contentHash):
            try await withDbRetry(
                logger: logger, context: "docID=\(cand.docID)", onRetry: { unhealthyRetries += 1 }
            ) {
                try await storeIndustryKpiFact(
                    existing: try await IndustryKpiFact.find(key, on: db),
                    docID: cand.docID, industryGroup: industryGroup,
                    code: cand.code, submitDateTime: cand.submitDateTime, payload: payload,
                    source: source, contentHash: contentHash, cacheVersion: industryKpiCacheVersion,
                    db: db)
            }
            stored += 1
        case .notApplicable(let reason):
            // 決定論の対象判定なので、対象外になった会社の既存 xbrl_facts もプレースホルダへ置換する。
            // LLM 経路の breakdown / notes とは違い、一時失敗で格下げすることはない。
            notApplicable += 1
            let placeholder = IndustryKpiSnapshotPayload(
                industryGroup: industryGroup, facts: [])
            try await withDbRetry(
                logger: logger, context: "docID=\(cand.docID)", onRetry: { unhealthyRetries += 1 }
            ) {
                try await storeIndustryKpiFact(
                    existing: try await IndustryKpiFact.find(key, on: db),
                    docID: cand.docID, industryGroup: industryGroup,
                    code: cand.code, submitDateTime: cand.submitDateTime,
                    payload: placeholder, source: industryKpiSourceNotApplicable,
                    contentHash: "", cacheVersion: industryKpiCacheVersion,
                    notApplicableReason: reason, db: db)
            }
        case .failed:
            failed += 1
            logger?.warning("業種KPI取り込み(\(industryGroup)) 取り込み失敗: docID=\(cand.docID) code=\(cand.code)")
        }
    }

    unhealthyRetries = 0
    var purged = 0
    if !sets.purge.isEmpty {
        let purgeDocIDs = Set(sets.purge)
        purged = try await withDbRetry(
            logger: logger, context: "業種KPI取り込み(\(industryGroup)) purge",
            onRetry: { unhealthyRetries += 1 }
        ) {
            let n = try await IndustryKpiFact.query(on: db)
                .filter(\.$industryGroup == industryGroup)
                .filter(\.$docID ~~ purgeDocIDs)
                .count()
            if n > 0 {
                try await IndustryKpiFact.query(on: db)
                    .filter(\.$industryGroup == industryGroup)
                    .filter(\.$docID ~~ purgeDocIDs)
                    .delete()
            }
            return n
        }
    }

    return IndustryKpiIngestSummary(
        attempted: attempted, stored: stored, notApplicable: notApplicable,
        failed: failed, skipped: skipped, purged: purged)
}

func storeIndustryKpiFact(
    existing: IndustryKpiFact?, docID: String, industryGroup: String, code: String,
    submitDateTime: String, payload: IndustryKpiSnapshotPayload, source: String, contentHash: String,
    cacheVersion: String, notApplicableReason: String? = nil, db: Database
) async throws {
    let applyFields: (IndustryKpiFact) -> Void = { row in
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
        let model = IndustryKpiFact(docID: docID, industryGroup: industryGroup)
        applyFields(model)
        try await createIdempotently(
            create: { try await model.create(on: db) },
            recover: {
                let key = IndustryKpiFact.compositeID(docID: docID, industryGroup: industryGroup)
                guard let recovered = try await IndustryKpiFact.find(key, on: db) else {
                    return false
                }
                applyFields(recovered)
                try await recovered.update(on: db)
                return true
            }
        )
    }
}

final class IndustryKpiSourceVersionOnly: Model, @unchecked Sendable {
    static let schema = IndustryKpiFact.schema

    @ID(custom: "id", generatedBy: .user)
    var id: String?

    @Field(key: "source")
    var source: String

    @Field(key: "cache_version")
    var cacheVersion: String

    @Field(key: "industry_group")
    var industryGroup: String

    @Field(key: "doc_id")
    var docID: String

    init() {}
}

func industryKpiClassifyRows(
    db: Database, industryGroup: String, docIDs: Set<String>
) async throws -> [IndustryKpiSourceVersionOnly] {
    guard !docIDs.isEmpty else { return [] }
    return try await IndustryKpiSourceVersionOnly.query(on: db)
        .filter(\.$industryGroup == industryGroup)
        .filter(\.$docID ~~ Array(docIDs))
        .all()
}

/// 業種 KPI（銀行）の対象会社: `listedCodes` のうち、提出者業種が銀行業、許可リスト、
/// statements の銀行様式 IS（`OrdinaryIncomeBNK`）、または BS 預金マーカーがある会社。
/// 預金マーカーだけの持株は候補に残し、抽出側が not_applicable プレースホルダへ置換する。
/// statements 未取り込みでも業種が銀行業か許可リストなら対象。
func industryKpiBankCandidateCodes(
    db: Database, listedCodes: Set<String>, bankIndustryCodes: Set<String>
) async throws -> Set<String> {
    let depositCodes = try await industryKpiStatementTagCodes(
        db: db, statementKey: "balance_sheet", tag: industryKpiBankDepositMarkerTag)
    let bankFormatCodes = try await industryKpiStatementTagCodes(
        db: db, statementKey: "income_statement", tag: industryKpiBankFormatIncomeStatementTag)
    return listedCodes.intersection(
        bankIndustryCodes
            .union(depositCodes)
            .union(bankFormatCodes)
            .union(industryKpiBankAlwaysIncludeCodes))
}

/// company_statements の指定配列にタグがある会社コード。payload は転送しない。
/// Postgres は jsonb 包含。SQLite（テスト）は TEXT の部分一致。
func industryKpiDepositMarkerCodes(db: Database) async throws -> Set<String> {
    try await industryKpiStatementTagCodes(
        db: db, statementKey: "balance_sheet", tag: industryKpiBankDepositMarkerTag)
}

func industryKpiStatementTagCodes(
    db: Database, statementKey: String, tag: String
) async throws -> Set<String> {
    let sql = try requireSQLDatabase(db)
    let query: SQLQueryString
    if sql.dialect.name == "postgresql" {
        let containment = #"[{"tag":"\#(tag)"}]"#
        switch statementKey {
        case "income_statement":
            query = """
                SELECT DISTINCT \(ident: "code") AS code
                FROM \(ident: CompanyStatement.schema)
                WHERE \(ident: "payload") -> 'income_statement' @> CAST(\(bind: containment) AS jsonb)
                """
        default:
            query = """
                SELECT DISTINCT \(ident: "code") AS code
                FROM \(ident: CompanyStatement.schema)
                WHERE \(ident: "payload") -> 'balance_sheet' @> CAST(\(bind: containment) AS jsonb)
                """
        }
    } else {
        let pattern = "%\"\(tag)\"%"
        query = """
            SELECT DISTINCT \(ident: "code") AS code
            FROM \(ident: CompanyStatement.schema)
            WHERE \(ident: "payload") LIKE \(bind: pattern)
            """
    }
    let rows = try await sql.raw(query).all()
    return Set(try rows.map { try $0.decode(column: "code", as: String.self) })
}
