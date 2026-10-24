// Statement 取り込み: 上場企業の有報について BS/PL/CF/SS を抽出し company_statements へ upsert する。
// 抽出は BlueTickerCore のファサード（extractStatement）に委譲し、ここでは対象選定・staleness 判定・
// DB upsert のみを担う（ネットワーク非依存でテスト可能）。
//
// `filingSectionCandidates`（`listedCodes × 会社有報(120・府令010) × 直近 years 件`）をそのまま再利用し、
// 返ってきた docID ごとに抽出結果を1行として格納する（company_filing_sections と同じ「1書類=1行」設計）。
// 複数年度対応は本関数の呼び出し元が filingSectionCandidates から複数 docID を受け取ることで自然に
// 達成され、`StatementAnalyzer` 自体を複数年度対応に拡張する必要はない
// （docs/statement.md）。
//
// 対象母集団は上場全体（呼び出し元が `listedCodes` に `listedCompanyCodes()` を渡す）。
// 日経225（`priorityIngestCodes()`）は処理順の先頭寄せのみ（membership ではない）。
//
// staleness 判定は決定論のみ（LLM 不要）のため内訳取り込みより単純: cache_version 不一致のみで
// 再抽出対象にする（company_breakdowns の needs_review 相当の概念は無い）。

import BltStoreCore
import BlueTickerCore
import FluentKit
import Foundation
import Logging

/// Statement 取り込み結果のサマリ。
public struct StatementIngestSummary: Sendable, Equatable {
    /// 抽出を試みた書類数（skip を除く）。
    public let attempted: Int
    /// 抽出・格納に成功した書類数（実データ行）。
    public let stored: Int
    /// 取得・抽出失敗でスキップした書類数。
    public let failed: Int
    /// US-GAAP 等の設計上の対象外（プレースホルダ行を格納）。
    public let notApplicable: Int
    /// 既に現行バージョンで抽出済みのためスキップした書類数。
    public let skipped: Int
    /// 保持窓（直近 years 件）を超えたため削除した既存行数。
    public let purged: Int
}

/// docID を受けて BS/PL/CF/SS 抽出結果を返す（成功 / 対象外 / 失敗）。
/// 本番は `context.extractStatement`、テストはフェイクを注入する。
public typealias StatementExtractor = @Sendable (String) async -> StatementDocResolveResult

/// `listedCodes`（呼び出し元は上場全体を渡す想定。日経225は `priorityCodes` で処理順のみ）の有報
/// （直近 years 年ぶん）を走査し、未抽出 or バージョン不一致のものを抽出・格納する。`limit` は新規抽出件数の上限（バッチ実行用）。
/// `explicitCodes` / `priorityCodes` は filing-sections/breakdowns と同じ意味。
/// `cachedDocIDs` はローカル XBRL 展開済み。処理順は各社の最新有報 → 前年以降。同一年次内は
/// 日経225 → キャッシュ済み → 欠測/版ずれのラウンドロビン。
/// `candidateSets` を渡すと候補選定クエリを省略する（呼び出し元がステージ間で候補を共有するとき）。
func runStatementIngest(
    db: Database, listedCodes: Set<String>, years: Int,
    limit: Int?, explicitCodes: Set<String>? = nil, priorityCodes: Set<String> = [],
    cachedDocIDs: Set<String> = [],
    candidateSets: FilingSectionCandidateSets? = nil,
    forceDocIDs: Set<String> = [],
    logger: Logger? = nil, extract: StatementExtractor
) async throws -> StatementIngestSummary {
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
    var failed = 0
    var notApplicable = 0
    var skipped = 0
    var unhealthyRetries = 0
    var missing: [FilingDocCandidate] = []
    var staleVersion: [FilingDocCandidate] = []

    let classifyRows = try await withDbRetry(
        logger: logger, context: "Statement 取り込み 分類", onRetry: { unhealthyRetries += 1 }
    ) {
        try await CompanyStatementCacheVersionOnly.query(on: db).all()
    }
    let classifyIndex = ingestIndexByID(classifyRows) { $0.id }

    for cand in baseCandidates {
        if forceDocIDs.contains(cand.docID) {
            missing.append(cand)
            continue
        }
        guard let existing = classifyIndex[cand.docID] else {
            missing.append(cand)
            continue
        }
        if existing.cacheVersion != statementCacheVersion {
            staleVersion.append(cand)
        } else {
            skipped += 1
        }
    }
    let candidates = ingestOrderedByYearRank(
        [missing, staleVersion],
        docIDOf: \.docID, codeOf: \.code, yearRankOf: \.yearRank,
        cachedDocIDs: cachedDocIDs, priorityCodes: priorityCodes)
    // 分類フェーズと実処理フェーズでリトライ予算を分ける。
    unhealthyRetries = 0

    for cand in candidates {
        if unhealthyRetries >= Api.ingestDbUnhealthyRetryThreshold {
            logger?.error(
                "DB接続が不安定なため Statement 取り込み を中断します(リトライ\(unhealthyRetries)回・残り\(candidates.count - attempted)件は次回スケジュールで再試行)"
            )
            break
        }
        let existing = try await withDbRetry(
            logger: logger, context: "docID=\(cand.docID)", onRetry: { unhealthyRetries += 1 }
        ) {
            try await CompanyStatement.find(cand.docID, on: db)
        }
        if !forceDocIDs.contains(cand.docID), let row = existing,
            row.cacheVersion == statementCacheVersion
        {
            skipped += 1
            continue
        }
        if let lim = limit, attempted >= lim { break }
        attempted += 1
        switch await extract(cand.docID) {
        case .resolved(let payload):
            try await withDbRetry(
                logger: logger, context: "docID=\(cand.docID)", onRetry: { unhealthyRetries += 1 }
            ) {
                try await storeCompanyStatement(
                    existing: try await CompanyStatement.find(cand.docID, on: db),
                    docID: cand.docID, code: cand.code,
                    submitDateTime: cand.submitDateTime, payload: payload, db: db)
            }
            stored += 1
        case .notApplicable:
            // US-GAAP 等。空プレースホルダを保存し、現行 version では再試行しない
            // （読み取りはプレースホルダを除外して 404 相当を維持）。
            try await withDbRetry(
                logger: logger, context: "docID=\(cand.docID)", onRetry: { unhealthyRetries += 1 }
            ) {
                try await storeCompanyStatement(
                    existing: try await CompanyStatement.find(cand.docID, on: db),
                    docID: cand.docID, code: cand.code,
                    submitDateTime: cand.submitDateTime,
                    payload: statementNotApplicablePlaceholderYear(docID: cand.docID), db: db)
            }
            notApplicable += 1
        case .failed:
            failed += 1
            logger?.warning("Statement 取り込み失敗: docID=\(cand.docID) code=\(cand.code)")
        }
    }

    // 保持窓を超えた既存行を purge する。分類・実処理フェーズとは別のリトライ予算を使う。
    unhealthyRetries = 0
    var purged = 0
    if !sets.purge.isEmpty {
        let purgeDocIDs = Set(sets.purge)
        purged = try await withDbRetry(
            logger: logger, context: "Statement 取り込み purge", onRetry: { unhealthyRetries += 1 }
        ) {
            let n = try await CompanyStatement.query(on: db)
                .filter(\.$id ~~ purgeDocIDs)
                .count()
            if n > 0 {
                try await CompanyStatement.query(on: db)
                    .filter(\.$id ~~ purgeDocIDs)
                    .delete()
            }
            return n
        }
    }

    return StatementIngestSummary(
        attempted: attempted, stored: stored, failed: failed, notApplicable: notApplicable,
        skipped: skipped, purged: purged)
}

/// 抽出済み BS/PL/CF/SS を company_statements へ書き込む（既存行があれば更新、無ければ作成）。
func storeCompanyStatement(
    existing: CompanyStatement?, docID: String, code: String, submitDateTime: String,
    payload: StatementYear, db: Database
) async throws {
    let applyFields: (CompanyStatement) -> Void = { row in
        row.code = code
        row.submitDateTime = submitDateTime
        row.payload = payload
        row.cacheVersion = statementCacheVersion
    }
    if let row = existing {
        applyFields(row)
        try await row.update(on: db)
    } else {
        let model = CompanyStatement()
        model.id = docID
        applyFields(model)
        try await createIdempotently(
            create: { try await model.create(on: db) },
            recover: {
                guard let recovered = try await CompanyStatement.find(docID, on: db) else { return false }
                applyFields(recovered)
                try await recovered.update(on: db)
                return true
            }
        )
    }
}

// MARK: - servable/unservable 集計

/// `cache_version` のみを対象にした軽量射影（`payload` の JSONB を転送しない）。
/// company_statements 全件の servable/unservable 集計用。
final class CompanyStatementCacheVersionOnly: Model, @unchecked Sendable {
    static let schema = CompanyStatement.schema

    @ID(custom: "doc_id", generatedBy: .user)
    var id: String?

    @Field(key: "cache_version")
    var cacheVersion: String

    init() {}
}

/// company_statements 全件を read 床（`statementMinServableVersion`）で集計する。
/// ingest サマリログに DB 全体のカバレッジを添えるため、`payload` を転送しない軽量クエリで行う。
func countServableStatements(db: Database) async throws -> (servable: Int, unservable: Int) {
    let versions = try await CompanyStatementCacheVersionOnly.query(on: db).all()
        .map(\.cacheVersion)
    let servable = versions.filter(isServableStatementCacheVersion).count
    return (servable, versions.count - servable)
}

// MARK: - read 経路（REST/MCP statement）

