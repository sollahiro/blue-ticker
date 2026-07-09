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
    db: Database, years: Int, limit: Int?, logger: Logger? = nil, compute: FinancialsComputer
) async throws -> Stage4IngestSummary {
    let (codes, highWaterMap) = try await distinctCompanyCodesWithHighWater(
        db: db, docTypes: Api.stage4FreshnessDocTypes, logger: logger)

    var attempted = 0
    var stored = 0
    var failed = 0
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
        if row.cacheVersion != companyFinancialsCacheVersion {
            staleVersion.append((code, highWater))
        } else if row.requestedYears < years {
            staleYears.append((code, highWater))
        } else if row.highWater != highWater {
            staleHighWater.append((code, highWater))
        } else {
            skipped += 1
        }
    }
    let candidates = missing + staleVersion + staleYears + staleHighWater
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
        guard let response = await compute(code) else {
            failed += 1
            logger?.warning("Stage 4 取り込み失敗: code=\(code)")
            continue
        }
        try await withDbRetry(
            logger: logger, context: "code=\(code)", onRetry: { unhealthyRetries += 1 }
        ) {
            try await storeCompanyFinancials(
                existing: existing, code: code, years: years, response: response,
                highWater: highWater, db: db)
        }
        stored += 1
    }

    return Stage4IngestSummary(
        attempted: attempted, stored: stored, failed: failed, skipped: skipped)
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
    if let row = existing {
        row.response = response
        row.cacheVersion = companyFinancialsCacheVersion
        row.requestedYears = years
        row.highWater = highWater
        try await row.update(on: db)
    } else {
        let model = CompanyFinancials()
        model.id = code
        model.response = response
        model.cacheVersion = companyFinancialsCacheVersion
        model.requestedYears = years
        model.highWater = highWater
        try await model.create(on: db)
    }
}

// MARK: - read 経路（REST financials）

/// 格納済み Stage 4 結果を code で引き、read 床以上 & 要求年数を満たすなら years に縮めた JSON を返す。
/// 床は `companyFinancialsMinServableVersion`（明示定数。現行版との完全一致ではない）。
/// 無い・床未満・年数不足なら nil（呼び出し側は 404。ライブ計算へはフォールバックしない）。
func loadStoredFinancials(code: String, years: Int, db: Database) async throws -> [String: Any]? {
    // years <= 0 は無効要求として nil（呼び出し側 404）。空 years の 200 を返さない。
    guard years > 0,
        let row = try await CompanyFinancials.find(code, on: db),
        isServableCompanyFinancialsCacheVersion(row.cacheVersion),
        row.requestedYears >= years
    else { return nil }
    return row.response.trimmed(toYears: years).jsonObject()
}
