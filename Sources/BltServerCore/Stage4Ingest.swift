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

/// Stage 4 取り込み結果のサマリ。
public struct Stage4IngestSummary: Sendable, Equatable {
    /// 計算を試みた企業数（skip を除く）。
    public let attempted: Int
    /// 計算・格納に成功した企業数。
    public let stored: Int
    /// データ無し等で計算できずスキップした企業数。
    public let failed: Int
    /// 既に現行バージョン・十分な年数で計算済みのためスキップした企業数。
    public let skipped: Int
}

/// 証券コードを受けて財務サマリを返す計算器（成功で response、失敗で nil）。
/// 本番は `context.computeFinancials`、テストはフェイクを注入する。
public typealias FinancialsComputer = @Sendable (String) async -> FinancialsResponse?

/// edinet_documents の企業（証券コード）を走査し、未計算 or バージョン不一致／年数不足のものを計算・格納する。
/// `limit` は新規計算件数の上限（計算が重いためバッチ実行用）。
func runStage4Ingest(
    db: Database, years: Int, limit: Int?, compute: FinancialsComputer
) async throws -> Stage4IngestSummary {
    let codes = try await distinctCompanyCodes(db: db)

    var attempted = 0
    var stored = 0
    var failed = 0
    var skipped = 0

    for code in codes {
        let existing = try await CompanyFinancials.find(code, on: db)
        if let row = existing, row.cacheVersion == blueTickerVersion, row.requestedYears >= years {
            skipped += 1
            continue
        }
        if let lim = limit, attempted >= lim { break }
        attempted += 1
        guard let response = await compute(code) else {
            failed += 1
            continue
        }
        try await storeCompanyFinancials(
            existing: existing, code: code, years: years, response: response, db: db)
        stored += 1
    }

    return Stage4IngestSummary(
        attempted: attempted, stored: stored, failed: failed, skipped: skipped)
}

/// edinet_documents の secCode（5 桁・末尾 0）から 4 桁コードを導出し、重複排除して返す。
/// secCode が無い／非上場（末尾 0 でない・桁数不一致）は対象外。
func distinctCompanyCodes(db: Database) async throws -> [String] {
    let documents = try await EdinetDocument.query(on: db).all()
    var seen = Set<String>()
    var codes: [String] = []
    for doc in documents {
        guard let sec = doc.secCode, sec.count == 5, sec.hasSuffix("0") else { continue }
        let code = String(sec.dropLast())
        if seen.insert(code).inserted { codes.append(code) }
    }
    return codes
}

/// 計算済みサマリを company_financials へ書き込む（既存行があれば更新、無ければ作成）。
/// cache_version に現行 blueTickerVersion、requested_years に計算年数を埋め込む。
func storeCompanyFinancials(
    existing: CompanyFinancials?, code: String, years: Int,
    response: FinancialsResponse, db: Database
) async throws {
    if let row = existing {
        row.response = response
        row.cacheVersion = blueTickerVersion
        row.requestedYears = years
        try await row.update(on: db)
    } else {
        let model = CompanyFinancials()
        model.id = code
        model.response = response
        model.cacheVersion = blueTickerVersion
        model.requestedYears = years
        try await model.create(on: db)
    }
}

// MARK: - read 経路（REST financials）

/// 格納済み Stage 4 結果を code で引き、現行バージョン & 要求年数を満たすなら years に縮めた JSON を返す。
/// 無い・古い・年数不足なら nil（呼び出し側はライブ計算へフォールバックする）。
func loadStoredFinancials(code: String, years: Int, db: Database) async throws -> [String: Any]? {
    // years <= 0 はライブ計算へ委ねる（ライブは該当書類なしで notFound を返す）。
    // DB 経路で空 years の 200 を返すとライブ経路（404）と挙動が食い違うため。
    guard years > 0,
        let row = try await CompanyFinancials.find(code, on: db),
        row.cacheVersion == blueTickerVersion,
        row.requestedYears >= years
    else { return nil }
    return row.response.trimmed(toYears: years).jsonObject()
}
