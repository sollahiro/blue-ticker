// `blt-server status-report`: 5 ステージ（financials / half_financials / filing_sections /
// breakdown_business / breakdown_geography）のカバレッジ・鮮度を集計し、JSON を stdout へ出す。
// 出力は `assets/apex-site/status.html`（静的公開ページ）を生成するシェルスクリプト
// （`scripts/generate-status-page.sh`）が読む契約。ここでは日経225構成銘柄の実コードは一切
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

/// company_financials の code / cache_version / updated_at のみを対象にした軽量射影。
final class CompanyFinancialsStatusProjection: Model, @unchecked Sendable {
    static let schema = CompanyFinancials.schema

    @ID(custom: "code", generatedBy: .user)
    var id: String?

    @Field(key: "cache_version")
    var cacheVersion: String

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}
}

/// company_half_financials の code / cache_version / updated_at のみを対象にした軽量射影。
final class CompanyHalfFinancialsStatusProjection: Model, @unchecked Sendable {
    static let schema = CompanyHalfFinancials.schema

    @ID(custom: "code", generatedBy: .user)
    var id: String?

    @Field(key: "cache_version")
    var cacheVersion: String

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

/// company_breakdowns の id / code / axis / source / cache_version / updated_at のみを対象にした軽量射影。
final class CompanyBreakdownStatusProjection: Model, @unchecked Sendable {
    static let schema = CompanyBreakdown.schema

    @ID(custom: "id", generatedBy: .user)
    var id: String?

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

/// 1 ステージ分の集計結果。`assets/apex-site/status.html` 生成スクリプトが読む JSON の要素。
public struct IngestStageStatus: Codable, Sendable, Equatable {
    public let key: String
    public let label: String
    public let companiesCovered: Int
    public let companiesTarget: Int
    public let coveragePct: Double
    /// financials / half_financials は 1 行 = 1 社（doc 次元を持たない）ため nil。
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
    let isCurrentVersion: Bool
    /// read 床（`*MinServableVersion`）以上で実際に 200 が返るか。`isCurrentVersion` より緩い条件
    /// （床以上なら現行版でなくても true）。
    let isServable: Bool
    let updatedAt: Date?
}

/// financials / half_financials 向け（1 行 = 1 社。doc 次元なし。current_version_pct の分母は
/// companiesTarget）。`targetCodes` に無い行（上場廃止等で対象母集団から外れたが、まだ purge
/// されていない残存行）は分子側から除外する。除外しないと coverage_pct / current_version_pct が
/// 100% を超えうる（分母を偽装するバグと同じ症状が分子の混入からも起こりうる。監査で指摘・修正）。
private func buildCompanyLevelStage(
    key: String, label: String, rows: [StatusRow], targetCodes: Set<String>, now: Date
) -> IngestStageStatus {
    let inScope = rows.filter { targetCodes.contains($0.code) }
    let companiesTarget = targetCodes.count
    let companiesCovered = Set(inScope.map(\.code)).count
    let currentCount = inScope.filter(\.isCurrentVersion).count
    let servableCount = inScope.filter(\.isServable).count
    let lastUpdated = inScope.compactMap(\.updatedAt).max()
    return IngestStageStatus(
        key: key, label: label,
        companiesCovered: companiesCovered, companiesTarget: companiesTarget,
        coveragePct: roundedPct(companiesCovered, companiesTarget),
        docsCovered: nil, docsTarget: nil,
        currentVersionPct: roundedPct(currentCount, companiesTarget),
        servableCovered: servableCount,
        servablePct: roundedPct(servableCount, companiesTarget),
        lastUpdated: lastUpdated.map { isoString(from: $0) },
        stale: isStageStale(lastUpdated: lastUpdated, now: now))
}

/// filing_sections / breakdown_* 向け（1 行 = 1 doc。current_version_pct の分母は docsTarget。
/// `roundedPct` 自体が分母 0 を 0.0 として扱うため、ここで `max(docsTarget, 1)` のような
/// 偽の分母は渡さない（渡すと companiesTarget=0 のとき current/1*100 で 100% 超の値が出る事故になる。
/// 日経225未配置環境での実測で発見・修正）。`targetCodes` に無い行（対象母集団から外れた残存行）は
/// `buildCompanyLevelStage` と同じ理由で分子側から除外する。
private func buildDocumentLevelStage(
    key: String, label: String, rows: [StatusRow], targetCodes: Set<String>, docsTarget: Int, now: Date
) -> IngestStageStatus {
    let inScope = rows.filter { targetCodes.contains($0.code) }
    let companiesTarget = targetCodes.count
    let companiesCovered = Set(inScope.map(\.code)).count
    let currentCount = inScope.filter(\.isCurrentVersion).count
    let servableCount = inScope.filter(\.isServable).count
    let lastUpdated = inScope.compactMap(\.updatedAt).max()
    return IngestStageStatus(
        key: key, label: label,
        companiesCovered: companiesCovered, companiesTarget: companiesTarget,
        coveragePct: roundedPct(companiesCovered, companiesTarget),
        docsCovered: inScope.count, docsTarget: docsTarget,
        currentVersionPct: roundedPct(currentCount, docsTarget),
        servableCovered: servableCount,
        servablePct: roundedPct(servableCount, docsTarget),
        lastUpdated: lastUpdated.map { isoString(from: $0) },
        stale: isStageStale(lastUpdated: lastUpdated, now: now))
}

/// 5 ステージ分の集計結果を組み立てる。`now` はテスト用に注入できる（既定は現在時刻）。
/// `listedCodes` は financials/half/filing_sections の対象母集団、`priorityCodes`
/// （`assets/nikkei225.csv`）は breakdown_business/breakdown_geography の対象母集団
/// （内訳取り込み の実 ingest スコープと同じ絞り込み）。
public func buildIngestStatusReport(
    db: Database, listedCodes: Set<String>, priorityCodes: Set<String>, now: Date = Date()
) async throws -> IngestStatusReport {
    // financials
    let finRows = try await CompanyFinancialsStatusProjection.query(on: db).all()
    let financials = buildCompanyLevelStage(
        key: "financials", label: "通期財務データ",
        rows: finRows.map {
            StatusRow(
                code: $0.id ?? "", isCurrentVersion: $0.cacheVersion == companyFinancialsCacheVersion,
                isServable: isServableCompanyFinancialsCacheVersion($0.cacheVersion),
                updatedAt: $0.updatedAt)
        },
        targetCodes: listedCodes, now: now)

    // half_financials
    let halfRows = try await CompanyHalfFinancialsStatusProjection.query(on: db).all()
    let halfFinancials = buildCompanyLevelStage(
        key: "half_financials", label: "半期財務データ",
        rows: halfRows.map {
            StatusRow(
                code: $0.id ?? "",
                isCurrentVersion: $0.cacheVersion == companyHalfFinancialsCacheVersion,
                isServable: isServableCompanyHalfFinancialsCacheVersion($0.cacheVersion),
                updatedAt: $0.updatedAt)
        },
        targetCodes: listedCodes, now: now)

    // filing_sections（対象母集団: listedCodes）
    let sectionRows = try await CompanyFilingSectionsStatusProjection.query(on: db).all()
    let sectionCandidates = try await filingSectionCandidates(
        db: db, listedCodes: listedCodes, years: filingSectionsIngestYears)
    let sectionsDocsTarget = sectionCandidates.keep.count
    let filingSections = buildDocumentLevelStage(
        key: "filing_sections", label: "有価証券報告書の本文データ",
        rows: sectionRows.map {
            StatusRow(
                code: $0.code, isCurrentVersion: $0.cacheVersion == filingSectionsCacheVersion,
                isServable: isServableFilingSectionsCacheVersion($0.cacheVersion),
                updatedAt: $0.updatedAt)
        },
        targetCodes: listedCodes, docsTarget: sectionsDocsTarget, now: now)

    // breakdown_business / breakdown_geography（対象母集団: priorityCodes＝日経225構成銘柄。
    // 実 内訳取り込み ingest と同じ母集団・窓のため候補集合は 1 回だけ計算して両軸で共有する）。
    let breakdownCandidates = try await filingSectionCandidates(
        db: db, listedCodes: priorityCodes, years: filingSectionsIngestYears)
    let breakdownDocsTarget = breakdownCandidates.keep.count

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
                code: row.code, isCurrentVersion: isCurrent, isServable: isServable,
                updatedAt: row.updatedAt)
        },
        targetCodes: priorityCodes, docsTarget: breakdownDocsTarget, now: now)

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
                code: row.code, isCurrentVersion: isCurrent, isServable: isServable,
                updatedAt: row.updatedAt)
        },
        targetCodes: priorityCodes, docsTarget: breakdownDocsTarget, now: now)

    return IngestStatusReport(
        generatedAt: isoString(from: now),
        stages: [financials, halfFinancials, filingSections, breakdownBusiness, breakdownGeography])
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
