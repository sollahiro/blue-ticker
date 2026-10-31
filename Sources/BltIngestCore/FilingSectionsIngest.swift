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
// 容量（Neon 512MB）のため上限を設ける。数値 facts 永続はしない。窓を緩めるなら
// filing-sections 自身の容量を見て決める。

import BltStoreCore
import BlueTickerCore
import FluentKit
import Foundation
import Logging
import SQLKit

/// 有報セクション取り込みで保持する有報の件数（1社あたり直近 N 件。有報は通常年1件のため ≈ N 年）。
/// 財務取り込みの financials 計算年数（6年）と揃える。
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
    forceDocIDs: Set<String> = [],
    logger: Logger? = nil, extract: FilingSectionsExtractor
) async throws -> FilingSectionsIngestSummary {
    let sets: FilingSectionCandidateSets
    if let candidateSets {
        sets = candidateSets
    } else {
        sets = try await filingSectionCandidates(
            db: db, listedCodes: listedCodes, explicitCodes: explicitCodes, years: years,
            logger: logger)
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
        if forceDocIDs.contains(cand.docID) {
            missing.append(cand)
            continue
        }
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
        // 存在確認と skip 判定は軽量射影で行い、ペイロードは読まない（BLT-200）。
        let existing = try await withDbRetry(
            logger: logger, context: "docID=\(cand.docID)", onRetry: { unhealthyRetries += 1 }
        ) {
            try await CompanyFilingSectionsCacheVersionOnly.find(cand.docID, on: db)
        }
        if !forceDocIDs.contains(cand.docID), let row = existing,
            row.cacheVersion == filingSectionsCacheVersion, row.sectionKeys == sectionKeys
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
                exists: try await CompanyFilingSectionsCacheVersionOnly.find(cand.docID, on: db) != nil,
                docID: cand.docID, code: cand.code,
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

/// 保持窓内の1書類。`yearRank` は当該社の窓内での新しさ（0 が最新の会社有報）。
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

/// 会社有報（120・府令010）の候補書類一覧を 1 回だけ読む。対象府令・書類種別は SQL で絞る。
/// ステージ間で候補集合を共有するときはこの一覧を `filingSectionCandidates(docs:...)` へ渡すと
/// DB 再往復しない。保持窓（社ごと直近 N 件）と purge は `filingSectionCandidates` が
/// この一覧の上で決める。種類・府令以外の行は SQL で落とす（全表 hydrate しない）。
func annualReportDisclosureDocs(db: Database, logger: Logger? = nil) async throws
    -> [EdinetDocumentListing]
{
    try await withDbRetry(logger: logger, context: "有報一覧") {
        try await EdinetDocumentListing.query(on: db)
            .filter(\.$docTypeCode == Api.docTypeAnnualReport)
            .filter(\.$ordinanceCode == Api.ordinanceCompanyDisclosure)
            .all()
    }
}

/// 取り込み候補（保持窓内）と purge 対象をまとめて返す。
/// 「上場（listedCodes）× 会社有報(120・府令010) × 各社 提出日時降順の直近 years 件」を keep、
/// それを超えた分を purge とする。docType 120 でも特定有価証券府令(030)の信託受益証券等は除外。
/// `explicitCodes` を渡すとさらにその集合へ絞る（`--codes` 手動指定。`nil` は絞り込みなし）。
/// `explicitDocIDs` を渡すと keep をその有報 docID だけにし、purge はしない（`--doc-ids`。
/// 訂正がある会社-FY だけの再 ingest 用。保持窓の外でも指定 doc は残す）。
/// `sec_code` が空の行は master の EDINETコード→証券コードで発行体を特定する。
func filingSectionCandidates(
    db: Database, listedCodes: Set<String>, explicitCodes: Set<String>? = nil, years: Int,
    logger: Logger? = nil, explicitDocIDs: Set<String>? = nil
) async throws -> FilingSectionCandidateSets {
    await filingSectionCandidates(
        docs: try annualReportDisclosureDocs(db: db, logger: logger),
        listedCodes: listedCodes, explicitCodes: explicitCodes, years: years,
        explicitDocIDs: explicitDocIDs)
}

/// `annualReportDisclosureDocs` の読み済み一覧から候補集合を組み立てる（DB 再往復なし）。
func filingSectionCandidates(
    docs: [EdinetDocumentListing], listedCodes: Set<String>, explicitCodes: Set<String>? = nil,
    years: Int, explicitDocIDs: Set<String>? = nil
) async -> FilingSectionCandidateSets {
    let listedSecByEdinet = await listedSecCodeByEdinetCode()

    // 4 桁コードごとに会社有報をまとめる。secCode は 5 桁（4 桁＋種別 1 桁 "0"）。
    // 空の secCode は listed な edinet_code があればその発行体に寄せる。
    var byCode: [String: [(docID: String, submitDateTime: String)]] = [:]
    for doc in docs {
        guard let docID = doc.id,
            let code = listedIssuerCode(
                secCode: doc.secCode, edinetCode: doc.edinetCode,
                listedSecCodeByEdinetCode: listedSecByEdinet)
        else { continue }
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
    if let ids = explicitDocIDs {
        var selected: [FilingDocCandidate] = []
        for (code, companyDocs) in byCode {
            let sorted = companyDocs.sorted { $0.submitDateTime > $1.submitDateTime }
            for (rank, d) in sorted.enumerated() where ids.contains(d.docID) {
                selected.append(
                    FilingDocCandidate(
                        docID: d.docID, code: code, submitDateTime: d.submitDateTime, yearRank: rank))
            }
        }
        selected.sort {
            if $0.yearRank != $1.yearRank { return $0.yearRank < $1.yearRank }
            if $0.submitDateTime != $1.submitDateTime { return $0.submitDateTime > $1.submitDateTime }
            return $0.docID < $1.docID
        }
        return FilingSectionCandidateSets(keep: selected, purge: [])
    }
    keep.sort {
        if $0.yearRank != $1.yearRank { return $0.yearRank < $1.yearRank }
        if $0.submitDateTime != $1.submitDateTime { return $0.submitDateTime > $1.submitDateTime }
        return $0.docID < $1.docID
    }
    return FilingSectionCandidateSets(keep: keep, purge: purge)
}

/// 抽出済みセクションを company_filing_sections へ書き込む（既存行があれば更新、無ければ作成）。
///
/// 既存行の更新ではペイロードを読まない。ペイロードは DB 側で比較し（Postgres の jsonb は
/// キー順に依らない等値）、内容が変わったときだけ書く。同じなら TOAST を書き直さない（BLT-200）。
/// 版（cache_version / section_keys）と updated_at は内容が同じでも必ず進める
/// （進めないと毎回 stale と判定されて再抽出が続く）。updated_at は「最後に確認した時刻」になる。
func storeCompanyFilingSections(
    exists: Bool, docID: String, code: String, submitDateTime: String,
    payload: FilingSectionsPayload, sectionKeys: String, db: Database
) async throws {
    if exists {
        try await updateCompanyFilingSectionsInPlace(
            docID: docID, code: code, submitDateTime: submitDateTime,
            payload: payload, sectionKeys: sectionKeys, db: db)
        return
    }
    let model = CompanyFilingSections()
    model.id = docID
    model.code = code
    model.submitDateTime = submitDateTime
    model.payload = payload
    model.cacheVersion = filingSectionsCacheVersion
    model.sectionKeys = sectionKeys
    try await createIdempotently(
        create: { try await model.create(on: db) },
        recover: {
            guard try await CompanyFilingSectionsCacheVersionOnly.find(docID, on: db) != nil else {
                return false
            }
            try await updateCompanyFilingSectionsInPlace(
                docID: docID, code: code, submitDateTime: submitDateTime,
                payload: payload, sectionKeys: sectionKeys, db: db)
            return true
        }
    )
}

/// 既存行をペイロードを読まずに更新する。ペイロードは内容が違うときだけ書き、その後で版を進める。
/// 途中で失敗しても「新しい版 + 古いペイロード」にならないよう、ペイロードを先に書く。
/// どちらの文も冪等なので withDbRetry での再実行に耐える。
func updateCompanyFilingSectionsInPlace(
    docID: String, code: String, submitDateTime: String,
    payload: FilingSectionsPayload, sectionKeys: String, db: Database
) async throws {
    let sql = try requireSQLDatabase(db)
    let payloadChanged: SQLQueryString = "\(ident: "payload") IS DISTINCT FROM \(bind: payload)"
    try await sql.update(CompanyFilingSections.schema)
        .set("payload", to: payload)
        .where("doc_id", .equal, docID)
        .where(payloadChanged)
        .run()
    try await CompanyFilingSections.query(on: db)
        .filter(\.$id == docID)
        .set(\.$code, to: code)
        .set(\.$submitDateTime, to: submitDateTime)
        .set(\.$cacheVersion, to: filingSectionsCacheVersion)
        .set(\.$sectionKeys, to: sectionKeys)
        .update()  // updated_at は Fluent が付ける
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

