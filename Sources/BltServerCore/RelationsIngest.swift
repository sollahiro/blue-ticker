// 関係取り込み（stage `relations`）: 上場企業の最新有報 1 件から、主要な顧客・関係会社・親会社等・
// 政策保有株式・大株主を company_relations へ書く（会社ごとに行を差し替える）。
// 抽出は Core（`BltServerContext.extractCompanyRelations`）。名前解決はすべて決定論（`RelationNameResolver`）で、
// 書き込み時に解き、最後に解き直す。解き直すのは (a) 解いたときの名簿（`resolver_key`）が今の名簿とずれた行
// （コードリストの更新・新規上場・上場廃止・社名変更・規則の版上げ）と、(b) この回で子会社索引の親が
// 変わった名前の行だけ（全行は読まない）。こうして最終状態は処理順に依らない。
// 子会社索引（上場会社の (連結子会社) 行の名前 → 親コード）は keyset で読み、プロセス内に持つ。
// 訂正 overlay 回帰の書類の行は索引に入れない。

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
    onlyDocIDs: Set<String>? = nil,
    retryJevPending: Bool = true, directory: RelationNameDirectory, logger: Logger? = nil,
    extract: CompanyRelationsExtracting
) async throws -> RelationsIngestSummary {
    // `--doc-ids` 指定時はその書類だけを対象にする（未指定の会社へ広げない）。
    let baseCandidates = try await latestAnnualReportPerCompany(
        db: db, listedCodes: listedCodes, explicitCodes: explicitCodes, logger: logger
    ).filter { onlyDocIDs?.contains($0.docID) ?? true }
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
        } else if existing[0].jevPending, retryJevPending {
            jevRetry.append(cand)
        } else {
            skipped += 1
        }
    }
    // Jev 保留の再試行は最後（limit の枠を新しい書類より先に使わない）。
    let candidates =
        ingestOrdered(
            interleaved([missing, staleDoc, staleVersion]),
            docIDOf: \.docID, codeOf: \.code, cachedDocIDs: cachedDocIDs, priorityCodes: priorityCodes)
        + ingestOrdered(
            jevRetry, docIDOf: \.docID, codeOf: \.code, cachedDocIDs: cachedDocIDs,
            priorityCodes: priorityCodes)

    var subsidiaryIndex = try await withDbRetry(logger: logger, context: "関係取り込み 子会社索引") {
        try await loadSubsidiaryNameIndex(db: db)
    }
    unhealthyRetries = 0
    var changedNames = Set<String>()
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
        changedNames.formUnion(subsidiaryIndex.replace(code: cand.code, with: models))
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
    let finalNames = changedNames
    let reresolved = try await withDbRetry(logger: logger, context: "関係取り込み 解き直し") {
        try await reresolveCompanyRelations(
            db: db, directory: directory, subsidiaryIndex: finalIndex, changedNames: finalNames)
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
        model.resolverKey = nil
        return
    }
    let resolved = RelationNameResolver.resolve(
        nameNorm: model.nameNorm, kind: model.kind, ownCode: model.code, directory: directory,
        subsidiaryParents: { subsidiaryIndex.parents(of: $0) })
    model.relatedCode = resolved.relatedCode
    model.resolution = resolved.resolution
    model.needsReview = model.kind == relationKindUnclassified || resolved.needsReview
    model.resolverKey = directory.fingerprint
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

    /// 会社の行を差し替えたとき、その会社の子会社名を入れ替える。親の集合が変わった名前を返す。
    @discardableResult
    mutating func replace(code: String, with models: [CompanyRelation]) -> Set<String> {
        let before = namesByCode[code] ?? []
        for name in before {
            parentsByName[name]?.remove(code)
            if parentsByName[name]?.isEmpty == true { parentsByName[name] = nil }
        }
        namesByCode[code] = nil
        for model in models
        where isSubsidiaryIndexRow(section: model.section, kind: model.kind, warning: model.warning) {
            add(code: code, nameNorm: model.nameNorm)
        }
        return before.symmetricDifference(namesByCode[code] ?? [])
    }
}

func isSubsidiaryIndexRow(section: String, kind: String, warning: String?) -> Bool {
    section == relationSectionAffiliatedEntities && kind == relationKindSubsidiary
        && !(warning.map { hasOverlayRegressionWarning([$0]) } ?? false)
}

/// 子会社索引を keyset で読む（全件 `.all()` はしない）。
func loadSubsidiaryNameIndex(db: Database) async throws -> SubsidiaryNameIndex {
    var index = SubsidiaryNameIndex()
    var after: UUID?
    while true {
        var query = CompanyRelation.query(on: db)
            .filter(\.$section == relationSectionAffiliatedEntities)
            .filter(\.$kind == relationKindSubsidiary)
            .filter(\.$warning == nil)
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

/// 解き直し。(a) `resolver_key` が今の名簿とずれた行（keyset）と、(b) 子会社索引の親が変わった名前の
/// 顧客・関連会社の行（`name_norm` 索引）だけを読む。結果が変わった行だけ書き、その数を返す
/// （名簿の指紋だけがずれた行は指紋だけをまとめて書く）。
func reresolveCompanyRelations(
    db: Database, directory: RelationNameDirectory, subsidiaryIndex: SubsidiaryNameIndex,
    changedNames: Set<String>
) async throws -> Int {
    var changed = 0
    func reresolve(_ rows: [CompanyRelation], renormalize: Bool) async throws -> [UUID] {
        var keyOnly: [UUID] = []
        for row in rows {
            let before = (row.nameNorm, row.relatedCode, row.resolution, row.needsReview)
            // 名簿の指紋には正規化の版も入るので、指紋がずれた行は name_norm も今の規則で作り直す。
            if renormalize { row.nameNorm = relationNameNorm(nameRaw: row.nameRaw, kind: row.kind) }
            applyResolution(to: row, directory: directory, subsidiaryIndex: subsidiaryIndex)
            if before != (row.nameNorm, row.relatedCode, row.resolution, row.needsReview) {
                try await row.update(on: db)
                changed += 1
            } else if let id = row.id {
                keyOnly.append(id)
            }
        }
        return keyOnly
    }

    var after: UUID?
    while true {
        var query = CompanyRelation.query(on: db)
            .filter(\.$kind != relationKindNone)
            .group(.or) { $0.filter(\.$resolverKey == nil).filter(\.$resolverKey != directory.fingerprint) }
        if let after { query = query.filter(\.$id > after) }
        let page = try await query.sort(\.$id).limit(relationsKeysetPage).all()
        let keyOnly = try await reresolve(page, renormalize: true)
        if !keyOnly.isEmpty {
            try await CompanyRelation.query(on: db).filter(\.$id ~~ keyOnly)
                .set(\.$resolverKey, to: directory.fingerprint).update()
        }
        guard page.count == relationsKeysetPage, let last = page.last?.id else { break }
        after = last
    }

    let indexedKinds = [relationKindCustomer, relationKindAffiliate]
        .filter(RelationNameResolver.usesSubsidiaryIndex(kind:))
    let names = changedNames.filter { !$0.isEmpty }.sorted()
    var start = 0
    while start < names.count {
        let chunk = Array(names[start..<min(start + relationsInsertChunk, names.count)])
        start += chunk.count
        let rows = try await CompanyRelation.query(on: db)
            .filter(\.$nameNorm ~~ chunk)
            .filter(\.$kind ~~ indexedKinds)
            .all()
        _ = try await reresolve(rows, renormalize: false)
    }
    return changed
}
