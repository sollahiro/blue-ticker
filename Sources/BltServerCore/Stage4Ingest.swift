// Stage 4 取り込み: edinet_documents に存在する企業（証券コード）について財務サマリを計算し、
// company_financials へ upsert する。計算は BlueTickerCore のファサード（computeFinancials）に
// 委譲し、ここでは企業選定・staleness 判定・DB upsert のみを担う（ネットワーク非依存でテスト可能）。
//
// 計算は HTML 依存抽出（US-GAAP・IFRS リース等）と waterfall を含み高コストなため、
// ローカル等のリソースに余裕がある環境で ingest し、Neon へ保存する。REST サーバー（Fly 等）は
// 読むだけにして OOM を回避する。read 経路は loadStoredFinancials。

import BlueTickerCore
import Fluent
import Foundation
import Logging

/// Stage 4 取り込み結果のサマリ。`notApplicable`（有価証券報告書未提出等、設計通り）を
/// `failed`（抽出できず要調査）と分けて数える点が Stage 4-half の `Stage4HalfIngestSummary` と同型
/// （issue #86）。
public struct Stage4IngestSummary: Sendable, Equatable {
    /// 計算を試みた企業数（skip を除く。notApplicable も含む＝実際に compute を呼んだ数）。
    public let attempted: Int
    /// 計算・格納に成功した企業数。
    public let stored: Int
    /// 書類はあるが抽出できず失敗した企業数（要調査）。
    public let failed: Int
    /// 有価証券報告書が未提出等、計算対象外だった企業数（設計通り・failed に含めない）。
    public let notApplicable: Int
    /// 既に現行バージョン・十分な年数で計算済みのためスキップした企業数。
    public let skipped: Int
}

/// 証券コードを受けて財務サマリを返す計算器（成功／対象外／失敗を区別する）。
/// 本番は `context.computeFinancials`、テストはフェイクを注入する。
public typealias FinancialsComputer = @Sendable (String) async -> FinancialsComputeResult

/// edinet_documents の企業（証券コード）を走査し、未計算 or バージョン不一致／年数不足のものを計算・格納する。
/// `limit` は新規計算件数の上限（計算が重いためバッチ実行用）。
/// `listedCodes` を渡すと候補をその集合に絞る（上場廃止・外国法人等、二度と成功しない企業への
/// 無駄なリトライを避ける。`nil` は絞り込みなし＝従来どおり全企業）。
/// `explicitCodes` を渡すと候補をその集合に絞る（`--codes` 手動指定。`nil` は絞り込みなし）。
/// `priorityCodes` に含まれる企業は候補の中で先頭へ寄せる（対象選定ではなく処理順序のみ。空集合は無効化）。
func runStage4Ingest(
    db: Database, years: Int, limit: Int?, listedCodes: Set<String>? = nil,
    explicitCodes: Set<String>? = nil, priorityCodes: Set<String> = [], logger: Logger? = nil,
    compute: FinancialsComputer
) async throws -> Stage4IngestSummary {
    let (allCodes, highWaterMap) = try await distinctCompanyCodesWithHighWater(
        db: db, docTypes: Api.stage4FreshnessDocTypes, logger: logger)
    let listedFiltered = listedCodes.map { listed in allCodes.filter { listed.contains($0) } } ?? allCodes
    let codes = explicitCodes.map { explicit in listedFiltered.filter { explicit.contains($0) } } ?? listedFiltered

    var attempted = 0
    var stored = 0
    var failed = 0
    var notApplicable = 0
    var skipped = 0
    var unhealthyRetries = 0
    var missing: [(code: String, highWater: String?)] = []
    var staleVersion: [(code: String, highWater: String?)] = []
    var staleYears: [(code: String, highWater: String?)] = []
    var staleHighWater: [(code: String, highWater: String?)] = []

    for code in codes {
        let highWater = highWaterMap[code]
        if unhealthyRetries >= Api.ingestDbUnhealthyRetryThreshold {
            logger?.error(
                "DB接続が不安定なため Stage 4 を中断します(リトライ\(unhealthyRetries)回・残り分類待ち企業あり)")
            break
        }
        let existing = try await withDbRetry(
            logger: logger, context: "code=\(code)", onRetry: { unhealthyRetries += 1 }
        ) {
            try await CompanyFinancials.find(code, on: db)
        }
        guard let row = existing else {
            missing.append((code, highWater))
            continue
        }
        if row.highWater != highWater {
            staleHighWater.append((code, highWater))
        } else if row.requestedYears < years {
            staleYears.append((code, highWater))
        } else if row.cacheVersion != companyFinancialsCacheVersion {
            staleVersion.append((code, highWater))
        } else {
            skipped += 1
        }
    }
    let candidates = prioritized(
        missing + staleHighWater + staleYears + staleVersion, codeOf: \.code,
        priorityCodes: priorityCodes)
    // 分類フェーズと実処理フェーズでリトライ予算を分ける。
    // 分類中の一過性リトライで処理フェーズが即中断しないようにする。
    unhealthyRetries = 0

    for cand in candidates {
        let code = cand.code
        let highWater = cand.highWater
        // continue（skip/failed）で下の判定を素通りされないよう、各項目の先頭で判定する。
        if unhealthyRetries >= Api.ingestDbUnhealthyRetryThreshold {
            logger?.error(
                "DB接続が不安定なため Stage 4 を中断します(リトライ\(unhealthyRetries)回・残り\(candidates.count - attempted)社は次回スケジュールで再試行)"
            )
            break
        }
        let existing = try await withDbRetry(
            logger: logger, context: "code=\(code)", onRetry: { unhealthyRetries += 1 }
        ) {
            try await CompanyFinancials.find(code, on: db)
        }
        if let row = existing, row.cacheVersion == companyFinancialsCacheVersion,
            row.requestedYears >= years, row.highWater == highWater {
            skipped += 1
            continue
        }
        if let lim = limit, attempted >= lim { break }
        attempted += 1
        switch await compute(code) {
        case .success(let response):
            try await withDbRetry(
                logger: logger, context: "code=\(code)", onRetry: { unhealthyRetries += 1 }
            ) {
                try await storeCompanyFinancials(
                    existing: existing, code: code, years: years, response: response,
                    highWater: highWater, db: db)
            }
            stored += 1
        case .notApplicable:
            // 有価証券報告書未提出等、設計通りの対象外。プレースホルダ行（years 空）を保存し、
            // 次回 ingest で highWater 一致のまま無駄な再試行を繰り返さないようにする
            // （読み取り経路 loadStoredFinancials/loadStoredAnalysis は years 空を検出し 404 を維持する）。
            // ノイズになるため warning ログは出さない。
            try await withDbRetry(
                logger: logger, context: "code=\(code)", onRetry: { unhealthyRetries += 1 }
            ) {
                try await storeCompanyFinancials(
                    existing: existing, code: code, years: years,
                    response: .notApplicablePlaceholder(code: code), highWater: highWater, db: db)
            }
            notApplicable += 1
        case .failed:
            failed += 1
            logger?.warning("Stage 4 取り込み失敗: code=\(code)")
        }
    }

    return Stage4IngestSummary(
        attempted: attempted, stored: stored, failed: failed, notApplicable: notApplicable,
        skipped: skipped)
}

/// edinet_documents の secCode（5 桁・末尾 0）から 4 桁コードを導出し、重複排除して返す。
/// secCode が無い／非上場（末尾 0 でない・桁数不一致）は対象外。
/// コード列挙は財務行の対象社集合を変えないため全 doc から行うが、high-water は
/// `docTypes` に含まれる doc のみで `code -> max(submitDateTime)`（辞書順）を構築する。
/// 該当種別の書類が無い社は high-water map に現れない（nil 扱い）。
func distinctCompanyCodesWithHighWater(
    db: Database, docTypes: Set<String>, logger: Logger? = nil
) async throws -> (codes: [String], highWater: [String: String]) {
    let documents = try await withDbRetry(logger: logger, context: "全書類一覧") {
        try await EdinetDocument.query(on: db).all()
    }
    var seen = Set<String>()
    var codes: [String] = []
    var highWater: [String: String] = [:]
    for doc in documents {
        guard let sec = doc.secCode, sec.count == 5, sec.hasSuffix("0") else { continue }
        let code = String(sec.dropLast())
        if seen.insert(code).inserted { codes.append(code) }

        guard let docType = doc.docTypeCode, docTypes.contains(docType) else { continue }
        if let current = highWater[code] {
            if doc.submitDateTime > current { highWater[code] = doc.submitDateTime }
        } else {
            highWater[code] = doc.submitDateTime
        }
    }
    return (codes, highWater)
}

/// 計算済みサマリを company_financials へ書き込む（既存行があれば更新、無ければ作成）。
/// cache_version に現行 companyFinancialsCacheVersion、requested_years に計算年数、
/// high_water に消費書類集合の現在の max(submitDateTime) を埋め込む。
func storeCompanyFinancials(
    existing: CompanyFinancials?, code: String, years: Int,
    response: FinancialsResponse, highWater: String?, db: Database
) async throws {
    let applyFields: (CompanyFinancials) -> Void = { row in
        row.response = response
        row.cacheVersion = companyFinancialsCacheVersion
        row.requestedYears = years
        row.highWater = highWater
    }
    if let row = existing {
        applyFields(row)
        try await row.update(on: db)
    } else {
        let model = CompanyFinancials()
        model.id = code
        applyFields(model)
        try await createIdempotently(
            create: { try await model.create(on: db) },
            recover: {
                guard let recovered = try await CompanyFinancials.find(code, on: db) else { return false }
                applyFields(recovered)
                try await recovered.update(on: db)
                return true
            }
        )
    }
}

// MARK: - servable/unservable 集計

/// `cache_version` のみを対象にした軽量射影（`response` の JSONB を転送しない）。
/// company_financials 全件の servable/unservable 集計用（`EdinetMasterSnapshotUpdatedAt` と同型）。
final class CompanyFinancialsCacheVersionOnly: Model, @unchecked Sendable {
    static let schema = CompanyFinancials.schema

    @ID(custom: "code", generatedBy: .user)
    var id: String?

    @Field(key: "cache_version")
    var cacheVersion: String

    init() {}
}

/// company_financials 全件を read 床（`companyFinancialsMinServableVersion`）で集計する。
/// ingest サマリログに DB 全体のカバレッジを添えるため、`response` を転送しない軽量クエリで行う。
func countServableCompanyFinancials(db: Database) async throws -> (servable: Int, unservable: Int) {
    let versions = try await CompanyFinancialsCacheVersionOnly.query(on: db).all()
        .map(\.cacheVersion)
    let servable = versions.filter(isServableCompanyFinancialsCacheVersion).count
    return (servable, versions.count - servable)
}

// MARK: - read 経路（REST financials）

/// 格納済み Stage 4 結果を code で引き、read 床以上 & 要求年数を満たすなら years に縮めた JSON を返す。
/// 床は `companyFinancialsMinServableVersion`（明示定数。現行版との完全一致ではない）。
/// 無い・床未満・年数不足なら nil（呼び出し側は 404。ライブ計算へはフォールバックしない）。
/// `years` 空（有価証券報告書未提出の notApplicable プレースホルダ、issue #86）も nil（404）とする。
func loadStoredFinancials(code: String, years: Int, db: Database) async throws -> [String: Any]? {
    // years <= 0 は無効要求として nil（呼び出し側 404）。空 years の 200 を返さない。
    guard years > 0,
        let row = try await CompanyFinancials.find(code, on: db),
        isServableCompanyFinancialsCacheVersion(row.cacheVersion),
        row.requestedYears >= years,
        row.response.yearCount > 0
    else { return nil }
    return row.response.trimmed(toYears: years).summaryJsonObject()
}

/// 格納済み Stage 4 結果を code で引き、増減分解フィールド（`docs/feature-tiers.md` の Analyze）を
/// 含めた JSON を返す。読み取り床・年数要件は `loadStoredFinancials` と同一（同じ格納行を使う。
/// 新規テーブル・cache_version は導入しない）。
func loadStoredAnalysis(code: String, years: Int, db: Database) async throws -> [String: Any]? {
    guard years > 0,
        let row = try await CompanyFinancials.find(code, on: db),
        isServableCompanyFinancialsCacheVersion(row.cacheVersion),
        row.requestedYears >= years,
        row.response.yearCount > 0
    else { return nil }
    return row.response.trimmed(toYears: years).analysisJsonObject()
}
