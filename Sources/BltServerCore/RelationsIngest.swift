// 関係取り込み（stage `relations`）: 上場企業の最新有報 1 件から、主要な顧客・関係会社・親会社等・
// 政策保有株式・大株主を company_relations へ書く（会社ごとに行を差し替える）。
// 抽出は Core（`BltServerContext.extractCompanyRelations`）。名前解決はすべて決定論（`RelationNameResolver`）で、
// 書き込み時に解き、最後に `unresolved` / `ambiguous` の行だけを解き直す（解決済みは触らない）。
// 子会社索引（上場会社の (連結子会社) 行の名前 → 親コード）は keyset で読み、プロセス内に持つ。

import BlueTickerCore
import Fluent
import Foundation
import Logging
import SQLKit

public struct RelationsIngestSummary: Sendable, Equatable {
    /// 抽出を試みた会社数（skip を除く）。
    public let attempted: Int
    /// 行を書き込んだ会社数。
    public let stored: Int
    /// 書類取得失敗の会社数（行は作らない）。
    public let failed: Int
    /// 同一 doc_id・現行版・Jev 保留なしで飛ばした会社数。
    public let skipped: Int
    /// 解き直しで結果が変わった既存行の数。
    public let reresolved: Int
}

/// docID・code を受けて抽出結果を返す。本番は `context.extractCompanyRelations`、テストはフェイク。
public typealias CompanyRelationsExtracting = @Sendable (String, String) async -> CompanyRelationsResolveResult

/// 1 回の挿入の行数（Postgres の bind 上限 65535 ÷ 列数に十分収まる）。
let relationsInsertChunk = 500
/// keyset 1 ページの行数。
let relationsKeysetPage = 2000

/// 分類用の会社単位の集約（payload 無し）。
struct RelationsClassifyRow: Equatable, Sendable {
    var code: String
    var docID: String
    var cacheVersion: String
    /// Jev 由来で区分が決まっていない行があるか（LLM の needs_review は現行版でも再試行する）。
    var jevPending: Bool
}

func runRelationsIngest(
    db: Database, listedCodes: Set<String>, limit: Int?, explicitCodes: Set<String>? = nil,
    priorityCodes: Set<String> = [], cachedDocIDs: Set<String> = [], forceDocIDs: Set<String> = [],
    directory: RelationNameDirectory, logger: Logger? = nil, extract: CompanyRelationsExtracting
) async throws -> RelationsIngestSummary {
    let baseCandidates = try await latestAnnualReportPerCompany(
        db: db, listedCodes: listedCodes, explicitCodes: explicitCodes, logger: logger)
    var unhealthyRetries = 0
    let classify = try await withDbRetry(
        logger: logger, context: "関係取り込み 分類", onRetry: { unhealthyRetries += 1 }
    ) {
        try await relationsClassifyRows(db: db)
    }
    var byCode: [String: [RelationsClassifyRow]] = [:]
    for row in classify { byCode[row.code, default: []].append(row) }

    typealias Candidate = (docID: String, code: String, submitDateTime: String)
    var missing: [Candidate] = []
    var staleDoc: [Candidate] = []
    var staleVersion: [Candidate] = []
    var jevRetry: [Candidate] = []
    var skipped = 0
    for cand in baseCandidates {
        guard !forceDocIDs.contains(cand.docID), let existing = byCode[cand.code], !existing.isEmpty else {
            missing.append(cand)
            continue
        }
        if existing.count > 1 || existing[0].docID != cand.docID {
            staleDoc.append(cand)
        } else if existing[0].cacheVersion != companyRelationsCacheVersion {
            staleVersion.append(cand)
        } else if existing[0].jevPending {
            jevRetry.append(cand)
        } else {
            skipped += 1
        }
    }
    let candidates = ingestOrdered(
        interleaved([missing, staleDoc, staleVersion, jevRetry]),
        docIDOf: \.docID, codeOf: \.code, cachedDocIDs: cachedDocIDs, priorityCodes: priorityCodes)

    var subsidiaryIndex = try await withDbRetry(logger: logger, context: "関係取り込み 子会社索引") {
        try await loadSubsidiaryNameIndex(db: db)
    }
    unhealthyRetries = 0
    var attempted = 0
    var stored = 0
    var failed = 0
    for cand in candidates {
        if unhealthyRetries >= Api.ingestDbUnhealthyRetryThreshold {
            logger?.error(
                "DB接続が不安定なため 関係取り込み を中断します(リトライ\(unhealthyRetries)回・残り\(candidates.count - attempted)件は次回スケジュールで再試行)"
            )
            break
        }
        if let lim = limit, attempted >= lim { break }
        attempted += 1
        guard case .extracted(let extraction) = await extract(cand.docID, cand.code) else {
            failed += 1
            logger?.warning("関係取り込み失敗: docID=\(cand.docID) code=\(cand.code)")
            continue
        }
        let models = relationModels(
            code: cand.code, docID: cand.docID, submitDateTime: cand.submitDateTime,
            extraction: extraction)
        subsidiaryIndex.replace(code: cand.code, with: models)
        for model in models {
            applyResolution(to: model, directory: directory, subsidiaryIndex: subsidiaryIndex)
        }
        try await withDbRetry(
            logger: logger, context: "code=\(cand.code)", onRetry: { unhealthyRetries += 1 }
        ) {
            try await replaceCompanyRelations(code: cand.code, with: models, db: db)
        }
        stored += 1
    }

    let finalIndex = subsidiaryIndex
    let reresolved = try await withDbRetry(logger: logger, context: "関係取り込み 解き直し") {
        try await reresolveCompanyRelations(
            db: db, directory: directory, subsidiaryIndex: finalIndex)
    }
    return RelationsIngestSummary(
        attempted: attempted, stored: stored, failed: failed, skipped: skipped, reresolved: reresolved)
}

/// 抽出結果を格納行にする（名前解決はまだ。`kind = none` の行は解決しない）。
func relationModels(
    code: String, docID: String, submitDateTime: String, extraction: CompanyRelationsExtraction
) -> [CompanyRelation] {
    let warning = extraction.warnings.isEmpty ? nil : extraction.warnings.joined(separator: " ")
    return extraction.rows.map {
        CompanyRelation(
            code: code, docID: docID, submitDateTime: submitDateTime, fyEnd: extraction.fyEnd,
            draft: $0, warning: warning)
    }
}

/// 1 行に名前解決を当てる。`needs_review` は「区分が決まっていない」か「候補が複数」のとき。
func applyResolution(
    to model: CompanyRelation, directory: RelationNameDirectory, subsidiaryIndex: SubsidiaryNameIndex
) {
    guard model.kind != relationKindNone else {
        model.relatedCode = nil
        model.resolution = nil
        return
    }
    let resolved = RelationNameResolver.resolve(
        nameNorm: model.nameNorm, kind: model.kind, ownCode: model.code, directory: directory,
        subsidiaryParents: { subsidiaryIndex.parents(of: $0) })
    model.relatedCode = resolved.relatedCode
    model.resolution = resolved.resolution
    model.needsReview = model.kind == relationKindUnclassified || resolved.needsReview
}

/// 会社の行を差し替える（同じトランザクションで削除 → 挿入）。
func replaceCompanyRelations(code: String, with models: [CompanyRelation], db: Database) async throws {
    try await db.transaction { tx in
        try await CompanyRelation.query(on: tx).filter(\.$code == code).delete()
        var start = 0
        while start < models.count {
            let end = min(start + relationsInsertChunk, models.count)
            try await Array(models[start..<end]).create(on: tx)
            start = end
        }
    }
}

/// 会社単位の分類（code・doc_id・cache_version ごとに 1 行）。payload は転送しない。
func relationsClassifyRows(db: Database) async throws -> [RelationsClassifyRow] {
    let sql = try requireSQLDatabase(db)
    let rows = try await sql.raw(
        """
        SELECT code, doc_id, cache_version,
               MAX(CASE WHEN decided_by = 'jev' AND kind = 'unclassified' THEN 1 ELSE 0 END) AS jev_pending
        FROM company_relations
        GROUP BY code, doc_id, cache_version
        """
    ).all()
    return try rows.map { row in
        RelationsClassifyRow(
            code: try row.decode(column: "code", as: String.self),
            docID: try row.decode(column: "doc_id", as: String.self),
            cacheVersion: try row.decode(column: "cache_version", as: String.self),
            jevPending: try sqlDecodeCount(row, column: "jev_pending") > 0)
    }
}

// MARK: - 子会社索引

/// 上場会社の「関係会社の状況」の (連結子会社) 行の `name_norm` → 親（提出会社）のコード集合。
struct SubsidiaryNameIndex: Sendable {
    private(set) var parentsByName: [String: Set<String>] = [:]
    private(set) var namesByCode: [String: Set<String>] = [:]

    func parents(of nameNorm: String) -> Set<String> {
        parentsByName[nameNorm] ?? []
    }

    mutating func add(code: String, nameNorm: String) {
        guard !nameNorm.isEmpty else { return }
        parentsByName[nameNorm, default: []].insert(code)
        namesByCode[code, default: []].insert(nameNorm)
    }

    /// 会社の行を差し替えたとき、その会社の子会社名を入れ替える。
    mutating func replace(code: String, with models: [CompanyRelation]) {
        for name in namesByCode[code] ?? [] {
            parentsByName[name]?.remove(code)
            if parentsByName[name]?.isEmpty == true { parentsByName[name] = nil }
        }
        namesByCode[code] = nil
        for model in models where isSubsidiaryIndexRow(section: model.section, kind: model.kind) {
            add(code: code, nameNorm: model.nameNorm)
        }
    }
}

func isSubsidiaryIndexRow(section: String, kind: String) -> Bool {
    section == relationSectionAffiliatedEntities && kind == relationKindSubsidiary
}

/// 子会社索引を keyset で読む（全件 `.all()` はしない）。
func loadSubsidiaryNameIndex(db: Database) async throws -> SubsidiaryNameIndex {
    var index = SubsidiaryNameIndex()
    var after: UUID?
    while true {
        var query = CompanyRelation.query(on: db)
            .filter(\.$section == relationSectionAffiliatedEntities)
            .filter(\.$kind == relationKindSubsidiary)
        if let after { query = query.filter(\.$id > after) }
        let page = try await query.sort(\.$id).limit(relationsKeysetPage)
            .field(\.$id).field(\.$code).field(\.$nameNorm)
            .all()
        for row in page { index.add(code: row.code, nameNorm: row.nameNorm) }
        guard page.count == relationsKeysetPage, let last = page.last?.id else { break }
        after = last
    }
    return index
}

/// `unresolved` / `ambiguous` の行だけを解き直す（keyset）。結果が変わった行だけ更新し、その数を返す。
func reresolveCompanyRelations(
    db: Database, directory: RelationNameDirectory, subsidiaryIndex: SubsidiaryNameIndex
) async throws -> Int {
    var changed = 0
    var after: UUID?
    let retryable = Array(relationRetryableResolutions).sorted()
    while true {
        var query = CompanyRelation.query(on: db).filter(\.$resolution ~~ retryable)
        if let after { query = query.filter(\.$id > after) }
        let page = try await query.sort(\.$id).limit(relationsKeysetPage).all()
        for row in page {
            let before = (row.relatedCode, row.resolution, row.needsReview)
            applyResolution(to: row, directory: directory, subsidiaryIndex: subsidiaryIndex)
            if before != (row.relatedCode, row.resolution, row.needsReview) {
                try await row.update(on: db)
                changed += 1
            }
        }
        guard page.count == relationsKeysetPage, let last = page.last?.id else { break }
        after = last
    }
    return changed
}
