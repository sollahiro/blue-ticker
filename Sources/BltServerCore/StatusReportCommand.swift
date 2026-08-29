// `blt-server status-report`: 5 ステージ（financials / statements / filing_sections /
// breakdown_business / breakdown_geography）のカバレッジ・鮮度・最新有報スライスを集計し、
// JSON を stdout へ出す。notes 等は含めない（上場正本の主要ステージのみ。全 ingest ではない）。
// 出力は静的公開ページ（`scripts/generate-status-page.sh`、パスは `BLT_STATUS_HTML`）
// が読む契約。ここでは日経225構成銘柄の実コードは一切
// 出力しない（集計件数のみ。Routes.swift 既存方針と同じく銘柄一覧の公開はしない）。
//
// 集計は `response`/`payload` の JSONB 本体を転送しない軽量射影モデル（各 Stage の
// `*CacheVersionOnly` と同型）で行う。DB ロジック（buildIngestStatusReport）は
// ネットワーク・EDINET 非依存でテスト可能。CLI エントリ（runStatusReportCommand）は
// Application 起動・DB 接続・stdout 出力のみを担う（他コマンドと同じ薄い I/O 層）。

import BlueTickerCore
import Fluent
import Foundation
import Vapor

// MARK: - 軽量射影モデル（`response`/`payload` の JSONB を転送しない）

/// company_financials の code / cache_version / high_water / updated_at のみを対象にした軽量射影。
final class CompanyFinancialsStatusProjection: Model, @unchecked Sendable {
    static let schema = CompanyFinancials.schema

    @ID(custom: "code", generatedBy: .user)
    var id: String?

    @Field(key: "cache_version")
    var cacheVersion: String

    /// 最新有報（yearRank 0）との鮮度比較用。未マイグレーション行は nil → 最新年度未カバー。
    @OptionalField(key: "high_water")
    var highWater: String?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}
}

/// company_filing_sections の doc_id / code / cache_version / updated_at のみを対象にした軽量射影。
final class CompanyFilingSectionsStatusProjection: Model, @unchecked Sendable {
    static let schema = CompanyFilingSections.schema

    @ID(custom: "doc_id", generatedBy: .user)
    var id: String?

    @Field(key: "code")
    var code: String

    @Field(key: "cache_version")
    var cacheVersion: String

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}
}

/// company_statements の doc_id / code / cache_version / updated_at のみを対象にした軽量射影。
final class CompanyStatementStatusProjection: Model, @unchecked Sendable {
    static let schema = CompanyStatement.schema

    @ID(custom: "doc_id", generatedBy: .user)
    var id: String?

    @Field(key: "code")
    var code: String

    @Field(key: "cache_version")
    var cacheVersion: String

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}
}

/// company_breakdowns の id / doc_id / code / axis / source / cache_version / updated_at のみを対象にした軽量射影。
final class CompanyBreakdownStatusProjection: Model, @unchecked Sendable {
    static let schema = CompanyBreakdown.schema

    @ID(custom: "id", generatedBy: .user)
    var id: String?

    @Field(key: "doc_id")
    var docID: String

    @Field(key: "code")
    var code: String

    @Field(key: "axis")
    var axis: String

    @Field(key: "source")
    var source: String

    @Field(key: "cache_version")
    var cacheVersion: String

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}
}

// MARK: - 集計結果の公開契約

/// 1 ステージ分の集計結果。`generate-status-page.sh` が読む JSON の要素。
public struct IngestStageStatus: Codable, Sendable, Equatable {
    public let key: String
    public let label: String
    public let companiesCovered: Int
    public let companiesTarget: Int
    public let coveragePct: Double
    /// financials は 1 行 = 1 社（doc 次元を持たない）ため nil。
    public let docsCovered: Int?
    public let docsTarget: Int?
    public let currentVersionPct: Double
    /// 対象件数（docsTarget があれば docsTarget、無ければ companiesTarget）のうち、read 床
    /// （各 Stage の `*MinServableVersion`）以上を満たす件数・割合。`currentVersionPct`
    /// （現行版との完全一致）とは別軸: 床以上だが現行版ではない行も含まれる。ただし breakdown の
    /// `not_applicable` 行のように床は満たしていても実際の read は 404（reason 付き）になる行も
    /// この集計には含む（`isServableBreakdown` の定義どおり。実 HTTP 200 率とは厳密には一致しない）。
    public let servableCovered: Int
    public let servablePct: Double
    /// ISO8601（UTC）。行が1件も無ければ nil。
    public let lastUpdated: String?
    public let stale: Bool
    /// 各社の最新有報（`yearRank == 0`）を母数にしたカバレッジ。母集団は `.agents/skills/xbrl-development/SKILL.md`。
    /// 分母は「最新 120 がある対象社／その書類」であり、120 が無い上場社は含めない。
    /// financials は 1 行 = 1 社のため、カバー条件は `high_water >=` その社の最新 120 提出日時。
    /// 他ステージは当該 docID の行があること。最新 120 が 0 件ならすべて 0。
    public let latestTarget: Int
    public let latestCovered: Int
    public let latestCoveragePct: Double
    public let latestCurrentPct: Double

    enum CodingKeys: String, CodingKey {
        case key
        case label
        case companiesCovered = "companies_covered"
        case companiesTarget = "companies_target"
        case coveragePct = "coverage_pct"
        case docsCovered = "docs_covered"
        case docsTarget = "docs_target"
        case currentVersionPct = "current_version_pct"
        case servableCovered = "servable_covered"
        case servablePct = "servable_pct"
        case lastUpdated = "last_updated"
        case stale
        case latestTarget = "latest_target"
        case latestCovered = "latest_covered"
        case latestCoveragePct = "latest_coverage_pct"
        case latestCurrentPct = "latest_current_pct"
    }
}

/// `blt-server status-report` の出力全体。
public struct IngestStatusReport: Codable, Sendable, Equatable {
    public let generatedAt: String
    public let stages: [IngestStageStatus]

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case stages
    }
}

// MARK: - 集計ロジック（DB のみ依存。EDINET/ネットワーク非依存でテスト可能）

/// `ISO8601DateFormatter` は Sendable でないためグローバル共有インスタンスを持たず、
/// 呼び出しのたびに生成する（呼び出し頻度が低く、性能上の問題にならないため）。
private func isoString(from date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.string(from: date)
}

/// target が 0 以下なら 0.0（NaN/クラッシュ回避）。それ以外は小数第1位で四捨五入。
private func roundedPct(_ numerator: Int, _ denominator: Int) -> Double {
    guard denominator > 0 else { return 0.0 }
    let raw = Double(numerator) / Double(denominator) * 100
    return (raw * 10).rounded() / 10
}

/// 最終更新が `Api.ingestFreshnessMaxAgeHours` 時間より古い、または行が1件も無ければ stale。
private func isStageStale(lastUpdated: Date?, now: Date) -> Bool {
    guard let lastUpdated else { return true }
    let maxAgeSeconds = Api.ingestFreshnessMaxAgeHours * 3600
    return now.timeIntervalSince(lastUpdated) > maxAgeSeconds
}

/// 射影行から共通集計（対象社カバレッジ・最終更新・staleness）を組み立てる最小単位。
private struct StatusRow {
    let code: String
    /// filing_sections / breakdown の突合用。financials は nil。
    let docID: String?
    let isCurrentVersion: Bool
    /// read 床（`*MinServableVersion`）以上で実際に 200 が返るか。`isCurrentVersion` より緩い条件
    /// （床以上なら現行版でなくても true）。
    let isServable: Bool
    let updatedAt: Date?
    /// financials の最新年度判定用。他ステージは nil。
    let highWater: String?
}

/// 最新有報（yearRank 0）スライス。`target == 0` なら pct は 0.0。
private struct LatestYearSlice {
    let target: Int
    let covered: Int
    let coveragePct: Double
    let currentPct: Double

    static let empty = LatestYearSlice(target: 0, covered: 0, coveragePct: 0, currentPct: 0)
}

/// financials: 最新 120 がある社を分母。カバーは `high_water >=` その提出日時。
private func latestYearForCompanies(
    rows: [StatusRow], latestDocs: [FilingDocCandidate]
) -> LatestYearSlice {
    var submitByCode: [String: String] = [:]
    for doc in latestDocs { submitByCode[doc.code] = doc.submitDateTime }
    let target = submitByCode.count
    guard target > 0 else { return .empty }
    let rowByCode = Dictionary(rows.map { ($0.code, $0) }, uniquingKeysWith: { _, last in last })
    var covered = 0
    var current = 0
    for (code, submit) in submitByCode {
        guard let row = rowByCode[code], let highWater = row.highWater, highWater >= submit
        else { continue }
        covered += 1
        if row.isCurrentVersion { current += 1 }
    }
    return LatestYearSlice(
        target: target, covered: covered,
        coveragePct: roundedPct(covered, target), currentPct: roundedPct(current, target))
}

/// filing_sections / breakdown: 最新 120 の docID を分母。カバーは当該行の存在。
private func latestYearForDocuments(
    rows: [StatusRow], latestDocs: [FilingDocCandidate]
) -> LatestYearSlice {
    let latestIDs = Set(latestDocs.map(\.docID))
    let target = latestDocs.count
    guard target > 0 else { return .empty }
    let matched = rows.filter { row in
        guard let id = row.docID else { return false }
        return latestIDs.contains(id)
    }
    let covered = matched.count
    let current = matched.filter(\.isCurrentVersion).count
    return LatestYearSlice(
        target: target, covered: covered,
        coveragePct: roundedPct(covered, target), currentPct: roundedPct(current, target))
}

/// financials 向け（1 行 = 1 社。doc 次元なし。current_version_pct の分母は
/// companiesTarget）。`targetCodes` に無い行（上場廃止等で対象母集団から外れたが、まだ purge
/// されていない残存行）は分子側から除外する。除外しないと coverage_pct / current_version_pct が
/// 100% を超えうる（分母を偽装するバグと同じ症状が分子の混入からも起こりうる。監査で指摘・修正）。
private func buildCompanyLevelStage(
    key: String, label: String, rows: [StatusRow], targetCodes: Set<String>,
    latestDocs: [FilingDocCandidate], now: Date
) -> IngestStageStatus {
    let inScope = rows.filter { targetCodes.contains($0.code) }
    let companiesTarget = targetCodes.count
    let companiesCovered = Set(inScope.map(\.code)).count
    let currentCount = inScope.filter(\.isCurrentVersion).count
    let servableCount = inScope.filter(\.isServable).count
    let lastUpdated = inScope.compactMap(\.updatedAt).max()
    let latest = latestYearForCompanies(rows: inScope, latestDocs: latestDocs)
    return IngestStageStatus(
        key: key, label: label,
        companiesCovered: companiesCovered, companiesTarget: companiesTarget,
        coveragePct: roundedPct(companiesCovered, companiesTarget),
        docsCovered: nil, docsTarget: nil,
        currentVersionPct: roundedPct(currentCount, companiesTarget),
        servableCovered: servableCount,
        servablePct: roundedPct(servableCount, companiesTarget),
        lastUpdated: lastUpdated.map { isoString(from: $0) },
        stale: isStageStale(lastUpdated: lastUpdated, now: now),
        latestTarget: latest.target, latestCovered: latest.covered,
        latestCoveragePct: latest.coveragePct, latestCurrentPct: latest.currentPct)
}

/// filing_sections / breakdown_* 向け（1 行 = 1 doc。current_version_pct の分母は docsTarget。
/// `roundedPct` 自体が分母 0 を 0.0 として扱うため、ここで `max(docsTarget, 1)` のような
/// 偽の分母は渡さない（渡すと companiesTarget=0 のとき current/1*100 で 100% 超の値が出る事故になる。
/// 日経225未配置環境での実測で発見・修正）。`targetCodes` に無い行（対象母集団から外れた残存行）は
/// `buildCompanyLevelStage` と同じ理由で分子側から除外する。
private func buildDocumentLevelStage(
    key: String, label: String, rows: [StatusRow], targetCodes: Set<String>, docsTarget: Int,
    latestDocs: [FilingDocCandidate], now: Date
) -> IngestStageStatus {
    let inScope = rows.filter { targetCodes.contains($0.code) }
    let companiesTarget = targetCodes.count
    let companiesCovered = Set(inScope.map(\.code)).count
    let currentCount = inScope.filter(\.isCurrentVersion).count
    let servableCount = inScope.filter(\.isServable).count
    let lastUpdated = inScope.compactMap(\.updatedAt).max()
    let latest = latestYearForDocuments(rows: inScope, latestDocs: latestDocs)
    return IngestStageStatus(
        key: key, label: label,
        companiesCovered: companiesCovered, companiesTarget: companiesTarget,
        coveragePct: roundedPct(companiesCovered, companiesTarget),
        docsCovered: inScope.count, docsTarget: docsTarget,
        currentVersionPct: roundedPct(currentCount, docsTarget),
        servableCovered: servableCount,
        servablePct: roundedPct(servableCount, docsTarget),
        lastUpdated: lastUpdated.map { isoString(from: $0) },
        stale: isStageStale(lastUpdated: lastUpdated, now: now),
        latestTarget: latest.target, latestCovered: latest.covered,
        latestCoveragePct: latest.coveragePct, latestCurrentPct: latest.currentPct)
}

/// 5 ステージ分の集計結果を組み立てる。`now` はテスト用に注入できる（既定は現在時刻）。
/// `listedCodes` は financials/statements/filing_sections/breakdown_business/breakdown_geography
/// の対象母集団。`priorityCodes`（`assets/nikkei225.csv`）は処理順の優先に使い、母集団そのものではない。
public func buildIngestStatusReport(
    db: Database, listedCodes: Set<String>, priorityCodes: Set<String>, now: Date = Date()
) async throws -> IngestStatusReport {
    // 日経225 は ingest の処理順のみ。カバレッジ分母は listedCodes（引数は呼び出し互換のため残す）。
    _ = priorityCodes
    // 最新有報スライスは financials / statements / sections / breakdown で共有する（候補集合は 1 回）。
    let candidates = try await filingSectionCandidates(
        db: db, listedCodes: listedCodes, years: filingSectionsIngestYears)
    let latestDocs = candidates.keep.filter { $0.yearRank == 0 }
    let docsTarget = candidates.keep.count

    // financials
    let finRows = try await CompanyFinancialsStatusProjection.query(on: db).all()
    let financials = buildCompanyLevelStage(
        key: "financials", label: "通期財務データ",
        rows: finRows.map {
            StatusRow(
                code: $0.id ?? "", docID: nil,
                isCurrentVersion: $0.cacheVersion == companyFinancialsCacheVersion,
                isServable: isServableCompanyFinancialsCacheVersion($0.cacheVersion),
                updatedAt: $0.updatedAt, highWater: $0.highWater)
        },
        targetCodes: listedCodes, latestDocs: latestDocs, now: now)

    // statements（対象母集団: listedCodes。filing_sections と同じ keep 窓・doc 単位）
    let statementRows = try await CompanyStatementStatusProjection.query(on: db).all()
    let statements = buildDocumentLevelStage(
        key: "statements", label: "財務諸表（BS/PL/CF/SS）",
        rows: statementRows.map {
            StatusRow(
                code: $0.code, docID: $0.id,
                isCurrentVersion: $0.cacheVersion == statementCacheVersion,
                isServable: isServableStatementCacheVersion($0.cacheVersion),
                updatedAt: $0.updatedAt, highWater: nil)
        },
        targetCodes: listedCodes, docsTarget: docsTarget, latestDocs: latestDocs, now: now)

    // filing_sections（対象母集団: listedCodes）
    let sectionRows = try await CompanyFilingSectionsStatusProjection.query(on: db).all()
    let filingSections = buildDocumentLevelStage(
        key: "filing_sections", label: "有価証券報告書の本文データ",
        rows: sectionRows.map {
            StatusRow(
                code: $0.code, docID: $0.id,
                isCurrentVersion: $0.cacheVersion == filingSectionsCacheVersion,
                isServable: isServableFilingSectionsCacheVersion($0.cacheVersion),
                updatedAt: $0.updatedAt, highWater: nil)
        },
        targetCodes: listedCodes, docsTarget: docsTarget, latestDocs: latestDocs, now: now)

    // breakdown_business / breakdown_geography（対象母集団: listedCodes＝上場全体。
    // 候補集合は filing_sections と同じ keep 窓）。
    let businessRows = try await CompanyBreakdownStatusProjection.query(on: db)
        .filter(\.$axis == breakdownAxisBusiness)
        .all()
    let breakdownBusiness = buildDocumentLevelStage(
        key: "breakdown_business", label: "事業別の売上内訳",
        rows: businessRows.map { row in
            // LLM 経由（segment_info_llm 等）は cache_version でゲートしない
            // （isVersionGatedBreakdownSource が false の source は常に「現行」扱い）。
            let isCurrent =
                !isVersionGatedBreakdownSource(row.source)
                || row.cacheVersion == breakdownCacheVersion(forAxis: breakdownAxisBusiness)
            let isServable = isServableBreakdown(
                source: row.source, cacheVersion: row.cacheVersion, axis: breakdownAxisBusiness)
            return StatusRow(
                code: row.code, docID: row.docID, isCurrentVersion: isCurrent, isServable: isServable,
                updatedAt: row.updatedAt, highWater: nil)
        },
        targetCodes: listedCodes, docsTarget: docsTarget, latestDocs: latestDocs, now: now)

    let geographyRows = try await CompanyBreakdownStatusProjection.query(on: db)
        .filter(\.$axis == breakdownAxisGeography)
        .all()
    let breakdownGeography = buildDocumentLevelStage(
        key: "breakdown_geography", label: "地域別の売上内訳",
        rows: geographyRows.map { row in
            let isCurrent =
                !isVersionGatedBreakdownSource(row.source)
                || row.cacheVersion == breakdownCacheVersion(forAxis: breakdownAxisGeography)
            let isServable = isServableBreakdown(
                source: row.source, cacheVersion: row.cacheVersion, axis: breakdownAxisGeography)
            return StatusRow(
                code: row.code, docID: row.docID, isCurrentVersion: isCurrent, isServable: isServable,
                updatedAt: row.updatedAt, highWater: nil)
        },
        targetCodes: listedCodes, docsTarget: docsTarget, latestDocs: latestDocs, now: now)

    return IngestStatusReport(
        generatedAt: isoString(from: now),
        stages: [financials, statements, filingSections, breakdownBusiness, breakdownGeography])
}

// MARK: - CLI エントリ

/// `blt-server status-report` の本体。Application を一時起動して DB を配線し、
/// 集計結果を pretty-printed JSON で stdout へ出す（ファイル書き込みはしない。
/// `scripts/generate-status-page.sh` が呼び出して JSON を捕捉し、静的ページへ反映する）。
public func runStatusReportCommand() async throws {
    guard let context = await makeBltServerContext() else {
        throw DocumentSyncError.apiKeyMissing
    }
    guard let urlString = Environment.get("DATABASE_URL"), !urlString.isEmpty else {
        throw DocumentSyncError.databaseUnavailable
    }

    var env = Environment(name: "production", arguments: ["blt-server"])
    try bootstrapBltLogging(from: &env)
    let app = try await Application.make(env)
    do {
        try await configureDatabase(app)
        let listed = await context.listedCompanyCodes()
        let priority = await context.priorityIngestCodes()
        let report = try await buildIngestStatusReport(
            db: app.db, listedCodes: listed, priorityCodes: priority)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        print(String(decoding: data, as: UTF8.self))
    } catch {
        try? await app.asyncShutdown()
        throw error
    }
    try await app.asyncShutdown()
}
