// 有報セクション取り込み: 上場企業（東証上場）の有報について、セクション本文を抽出し
// company_filing_sections へ upsert する。抽出は BlueTickerCore のファサード（extractFilingSections）に
// 委譲し、ここでは対象選定・staleness 判定・DB upsert のみを担う（ネットワーク非依存でテスト可能）。
//
// filing-content のライブ抽出は大企業有報で 1GB OOM を実測したため撤去し、read は本テーブルの
// DB read-only（loadStoredFilingSections）へ移した。抽出（重い SwiftSoup）はローカル等の余裕ある
// 環境で ingest し、Neon へ保存する。
//
// 対象は「東証上場（EDINET 上場区分）× 有報(120) × 直近 years 件（≈ years 年。有報は通常年1件）」。
// 直近 years 件を超えた過去書類は既存行があれば purge（削除）し、無期限累積を防ぐ。窓は財務取り込み
// （financials 6年）と揃え、トレンド分析と同じ期間分の本文を読めるようにする。
// 容量（Neon 512MB）のため上限を設ける。ストレージ強化＝issue #22 決定後に緩められる。

import BlueTickerCore
import Fluent
import Foundation
import Logging

/// 有報セクション取り込みで保持する有報の件数（1社あたり直近 N 件。有報は通常年1件のため ≈ N 年）。
/// 財務取り込みの financials 計算年数（6年）と揃える。ストレージ強化後に緩められる。
let filingSectionsIngestYears = 6

/// 有報セクション取り込み結果のサマリ。
public struct FilingSectionsIngestSummary: Sendable, Equatable {
    /// 抽出を試みた書類数（skip を除く）。
    public let attempted: Int
    /// 抽出・格納に成功した書類数。
    public let stored: Int
    /// 取得失敗等で格納できずスキップした書類数。
    public let failed: Int
    /// 既に現行バージョン・同一セクション集合で抽出済みのためスキップした書類数。
    public let skipped: Int
    /// 保持窓（直近 years 件）を超えたため削除した既存行数。
    public let purged: Int
}

/// docID を受けてセクション本文 payload を返す抽出器（成功で payload、失敗で nil）。
/// 本番は `context.extractFilingSections`、テストはフェイクを注入する。
public typealias FilingSectionsExtractor = @Sendable (String) async -> FilingSectionsPayload?

/// 上場企業の有報（直近 years 年ぶん）を走査し、未抽出 or バージョン／セクション集合不一致のものを
/// 抽出・格納する。`limit` は新規抽出件数の上限（抽出が重いためバッチ実行用）。
/// `explicitCodes` を渡すと候補をその集合に絞る（`--codes` 手動指定。`nil` は絞り込みなし）。
/// `priorityCodes` に含まれる企業の書類は候補の中で先頭へ寄せる（対象選定ではなく処理順序のみ。空集合は無効化）。
/// `cachedDocIDs` はローカル XBRL 展開済み。処理順は各社の最新有報 → 前年以降。同一年次内は
/// 日経225 → キャッシュ済み → 欠測/版ずれのラウンドロビン。
/// `candidateSets` を渡すと候補選定クエリを省略する（呼び出し元がステージ間で候補を共有するとき）。
func runFilingSectionsIngest(
    db: Database, listedCodes: Set<String>, years: Int, sectionKeys: String,
    limit: Int?, explicitCodes: Set<String>? = nil, priorityCodes: Set<String> = [],
    cachedDocIDs: Set<String> = [],
    candidateSets: FilingSectionCandidateSets? = nil,
    logger: Logger? = nil, extract: FilingSectionsExtractor
) async throws -> FilingSectionsIngestSummary {
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
    var skipped = 0
    var unhealthyRetries = 0
    var missing: [FilingDocCandidate] = []
    var staleVersion: [FilingDocCandidate] = []
    var staleSectionKeys: [FilingDocCandidate] = []

    let classifyRows = try await withDbRetry(
        logger: logger, context: "有報セクション取り込み 分類", onRetry: { unhealthyRetries += 1 }
    ) {
        try await CompanyFilingSectionsCacheVersionOnly.query(on: db).all()
    }
    let classifyIndex = ingestIndexByID(classifyRows) { $0.id }

    for cand in baseCandidates {
        guard let existing = classifyIndex[cand.docID] else {
            missing.append(cand)
            continue
        }
        if existing.cacheVersion != filingSectionsCacheVersion {
            staleVersion.append(cand)
        } else if existing.sectionKeys != sectionKeys {
            staleSectionKeys.append(cand)
        } else {
            skipped += 1
        }
    }
    let candidates = ingestOrderedByYearRank(
        [missing, staleVersion, staleSectionKeys],
        docIDOf: \.docID, codeOf: \.code, yearRankOf: \.yearRank,
        cachedDocIDs: cachedDocIDs, priorityCodes: priorityCodes)
    // 分類フェーズと実処理フェーズでリトライ予算を分ける。
    // 分類中の一過性リトライで処理フェーズが即中断しないようにする。
    unhealthyRetries = 0

    for cand in candidates {
        // continue（skip/failed）で下の判定を素通りされないよう、各項目の先頭で判定する。
        if unhealthyRetries >= Api.ingestDbUnhealthyRetryThreshold {
            logger?.error(
                "DB接続が不安定なため 有報セクション取り込み を中断します(リトライ\(unhealthyRetries)回・残り\(candidates.count - attempted)件は次回スケジュールで再試行)"
            )
            break
        }
        let existing = try await withDbRetry(
            logger: logger, context: "docID=\(cand.docID)", onRetry: { unhealthyRetries += 1 }
        ) {
            try await CompanyFilingSections.find(cand.docID, on: db)
        }
        if let row = existing, row.cacheVersion == filingSectionsCacheVersion,
            row.sectionKeys == sectionKeys
        {
            skipped += 1
            continue
        }
        if let lim = limit, attempted >= lim { break }
        attempted += 1
        guard let payload = await extract(cand.docID) else {
            failed += 1
            logger?.warning("有報セクション取り込み失敗: docID=\(cand.docID) code=\(cand.code)")
            continue
        }
        try await withDbRetry(
            logger: logger, context: "docID=\(cand.docID)", onRetry: { unhealthyRetries += 1 }
        ) {
            try await storeCompanyFilingSections(
                existing: existing, docID: cand.docID, code: cand.code,
                submitDateTime: cand.submitDateTime, payload: payload,
                sectionKeys: sectionKeys, db: db)
        }
        stored += 1
    }

    // 保持窓を超えた既存行を purge する。分類・実処理フェーズとは別のリトライ予算を使う。
    unhealthyRetries = 0
    var purged = 0
    if !sets.purge.isEmpty {
        let purgeDocIDs = Set(sets.purge)
        purged = try await withDbRetry(
            logger: logger, context: "有報セクション取り込み purge", onRetry: { unhealthyRetries += 1 }
        ) {
            let n = try await CompanyFilingSections.query(on: db)
                .filter(\.$id ~~ purgeDocIDs)
                .count()
            if n > 0 {
                try await CompanyFilingSections.query(on: db)
                    .filter(\.$id ~~ purgeDocIDs)
                    .delete()
            }
            return n
        }
    }

    return FilingSectionsIngestSummary(
        attempted: attempted, stored: stored, failed: failed, skipped: skipped, purged: purged)
}

/// 保持窓内の1書類。`yearRank` は当該社の窓内での新しさ（0 が最新有報）。
struct FilingDocCandidate: Equatable, Sendable {
    var docID: String
    var code: String
    var submitDateTime: String
    var yearRank: Int

    init(docID: String, code: String, submitDateTime: String, yearRank: Int = 0) {
        self.docID = docID
        self.code = code
        self.submitDateTime = submitDateTime
        self.yearRank = yearRank
    }
}

/// 取り込み候補（保持窓内。docID・4桁コード・提出日時・yearRank）と、保持窓を超えた既存書類の docID（purge 対象）。
struct FilingSectionCandidateSets {
    let keep: [FilingDocCandidate]
    let purge: [String]
}

/// 取り込み候補（保持窓内）と purge 対象をまとめて返す。
/// 「上場（listedCodes）× 有報(120) × 各社 提出日時降順の直近 years 件」を keep、それを超えた分を purge とする。
/// `explicitCodes` を渡すとさらにその集合へ絞る（`--codes` 手動指定。`nil` は絞り込みなし）。
func filingSectionCandidates(
    db: Database, listedCodes: Set<String>, explicitCodes: Set<String>? = nil, years: Int,
    logger: Logger? = nil
) async throws -> FilingSectionCandidateSets {
    let documents = try await withDbRetry(logger: logger, context: "有報一覧") {
        try await EdinetDocument.query(on: db)
            .filter(\.$docTypeCode == Api.docTypeAnnualReport)
            .all()
    }

    // 4 桁コードごとに有報をまとめる。secCode は 5 桁（4 桁＋種別 1 桁 "0"）。
    var byCode: [String: [(docID: String, submitDateTime: String)]] = [:]
    for doc in documents {
        guard let docID = doc.id,
            let sec = doc.secCode, sec.count == 5, sec.hasSuffix("0")
        else { continue }
        let code = String(sec.dropLast())
        guard listedCodes.contains(code) else { continue }
        if let explicit = explicitCodes, !explicit.contains(code) { continue }
        byCode[code, default: []].append((docID, doc.submitDateTime))
    }

    var keep: [FilingDocCandidate] = []
    var purge: [String] = []
    for (code, docs) in byCode {
        let sorted = docs.sorted { $0.submitDateTime > $1.submitDateTime }
        for (rank, d) in sorted.prefix(years).enumerated() {
            keep.append(
                FilingDocCandidate(
                    docID: d.docID, code: code, submitDateTime: d.submitDateTime, yearRank: rank))
        }
        for d in sorted.dropFirst(years) {
            purge.append(d.docID)
        }
    }
    keep.sort {
        if $0.yearRank != $1.yearRank { return $0.yearRank < $1.yearRank }
        if $0.submitDateTime != $1.submitDateTime { return $0.submitDateTime > $1.submitDateTime }
        return $0.docID < $1.docID
    }
    return FilingSectionCandidateSets(keep: keep, purge: purge)
}

/// 抽出済みセクションを company_filing_sections へ書き込む（既存行があれば更新、無ければ作成）。
func storeCompanyFilingSections(
    existing: CompanyFilingSections?, docID: String, code: String, submitDateTime: String,
    payload: FilingSectionsPayload, sectionKeys: String, db: Database
) async throws {
    let applyFields: (CompanyFilingSections) -> Void = { row in
        row.code = code
        row.submitDateTime = submitDateTime
        row.payload = payload
        row.cacheVersion = filingSectionsCacheVersion
        row.sectionKeys = sectionKeys
    }
    if let row = existing {
        applyFields(row)
        try await row.update(on: db)
    } else {
        let model = CompanyFilingSections()
        model.id = docID
        applyFields(model)
        try await createIdempotently(
            create: { try await model.create(on: db) },
            recover: {
                guard let recovered = try await CompanyFilingSections.find(docID, on: db) else { return false }
                applyFields(recovered)
                try await recovered.update(on: db)
                return true
            }
        )
    }
}

// MARK: - servable/unservable 集計

/// `cache_version` のみを対象にした軽量射影（`payload` の JSONB を転送しない）。
/// company_filing_sections 全件の servable/unservable 集計用。
final class CompanyFilingSectionsCacheVersionOnly: Model, @unchecked Sendable {
    static let schema = CompanyFilingSections.schema

    @ID(custom: "doc_id", generatedBy: .user)
    var id: String?

    @Field(key: "cache_version")
    var cacheVersion: String

    @Field(key: "section_keys")
    var sectionKeys: String

    init() {}
}

/// company_filing_sections 全件を read 床（`filingSectionsMinServableVersion`）で集計する。
/// ingest サマリログに DB 全体のカバレッジを添えるため、`payload` を転送しない軽量クエリで行う。
func countServableFilingSections(db: Database) async throws -> (servable: Int, unservable: Int) {
    let versions = try await CompanyFilingSectionsCacheVersionOnly.query(on: db).all()
        .map(\.cacheVersion)
    let servable = versions.filter(isServableFilingSectionsCacheVersion).count
    return (servable, versions.count - servable)
}

// MARK: - read 経路（REST filing-content）

/// 格納済み 有報セクション取り込み セクションを引いて公開契約 {code, doc_id, sections} を返す。
/// doc_id 指定時はその書類（当該 code のもの）、省略時は当該 code の最新有報（提出日時降順のうち床以上）。
/// 床は `filingSectionsMinServableVersion`（明示定数。現行版との完全一致ではない）。
/// 無い・床未満なら nil（呼び出し側は 404。ライブ抽出へはフォールバックしない）。
func loadStoredFilingSections(
    code: String, docId: String?, sections: [String]?, db: Database
) async throws -> [String: Any]? {
    let code4 = String(code.prefix(4))
    guard !code4.isEmpty, code4.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }

    let row: CompanyFilingSections?
    if let docId, !docId.isEmpty {
        // 指定書類。取り違え防止に当該 code の書類であることを確認する。
        let found = try await CompanyFilingSections.find(docId, on: db)
        row = (found?.code == code4) ? found : nil
    } else {
        // 最新有報（提出日時降順のうち、read 床以上の先頭）。
        // 床判定は SQL では表現しにくいため code 単位で取得してから選ぶ（社あたり直近数件）。
        let candidates = try await CompanyFilingSections.query(on: db)
            .filter(\.$code == code4)
            .sort(\.$submitDateTime, .descending)
            .all()
        row = candidates.first { isServableFilingSectionsCacheVersion($0.cacheVersion) }
    }

    guard let row, isServableFilingSectionsCacheVersion(row.cacheVersion), let docID = row.id else {
        return nil
    }
    return [
        "code": code4,
        "doc_id": docID,
        "sections": row.payload.sectionsObject(sections: sections),
    ]
}
