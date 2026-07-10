// 半期 Stage 4 取り込み: edinet_documents に存在する企業（証券コード）について半期財務サマリを
// 計算し、company_half_financials へ upsert する。計算は BlueTickerCore のファサード
// （computeHalfFinancials）に委譲し、ここでは企業選定・staleness 判定・DB upsert のみを担う
// （ネットワーク非依存でテスト可能）。通期 Stage 4（Stage4Ingest.swift）と同構造。
//
// 計算は HalfYearAnalyzer（FY/2Q から H1/H2 導出・waterfall）を含み高コストなため、ローカル等で
// ingest し Neon へ保存する。REST サーバー（Fly 等）は読むだけにして OOM を回避する。
// read 経路は loadStoredHalfFinancials。

import BlueTickerCore
import Fluent
import Foundation
import Logging

/// 半期 Stage 4 取り込みで格納する年数（HalfYearAnalyzer の探索上限＝全集合）。
/// read 時に要求年数へ縮める（REST の half-financials は years 既定 3）。
let stage4HalfIngestYears = Api.halfMaxYears

/// 証券コードを受けて半期財務サマリを返す計算器（成功で response、失敗で nil）。
/// 本番は `context.computeHalfFinancials`、テストはフェイクを注入する。
public typealias HalfFinancialsComputer = @Sendable (String) async -> HalfFinancialsResponse?

/// edinet_documents の企業（証券コード）を走査し、未計算 or バージョン不一致／年数不足のものを計算・格納する。
/// `limit` は新規計算件数の上限（計算が重いためバッチ実行用）。通期 Stage 4 と同ロジック。
/// `listedCodes` を渡すと候補をその集合に絞る（上場廃止・外国法人等、二度と成功しない企業への
/// 無駄なリトライを避ける。`nil` は絞り込みなし＝従来どおり全企業）。
func runStage4HalfIngest(
    db: Database, years: Int, limit: Int?, listedCodes: Set<String>? = nil,
    logger: Logger? = nil, compute: HalfFinancialsComputer
) async throws -> Stage4IngestSummary {
    let (allCodes, highWaterMap) = try await distinctCompanyCodesWithHighWater(
        db: db, docTypes: Api.stage4HalfFreshnessDocTypes, logger: logger)
    let codes = listedCodes.map { listed in allCodes.filter { listed.contains($0) } } ?? allCodes

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
                "DB接続が不安定なため Stage 4-half を中断します(リトライ\(unhealthyRetries)回・残り分類待ち企業あり)")
            break
        }
        let existing = try await withDbRetry(
            logger: logger, context: "code=\(code)", onRetry: { unhealthyRetries += 1 }
        ) {
            try await CompanyHalfFinancials.find(code, on: db)
        }
        guard let row = existing else {
            missing.append((code, highWater))
            continue
        }
        if row.cacheVersion != companyHalfFinancialsCacheVersion {
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
                "DB接続が不安定なため Stage 4-half を中断します(リトライ\(unhealthyRetries)回・残り\(candidates.count - attempted)社は次回スケジュールで再試行)"
            )
            break
        }
        let existing = try await withDbRetry(
            logger: logger, context: "code=\(code)", onRetry: { unhealthyRetries += 1 }
        ) {
            try await CompanyHalfFinancials.find(code, on: db)
        }
        if let row = existing, row.cacheVersion == companyHalfFinancialsCacheVersion,
            row.requestedYears >= years, row.highWater == highWater {
            skipped += 1
            continue
        }
        if let lim = limit, attempted >= lim { break }
        attempted += 1
        guard let response = await compute(code) else {
            failed += 1
            logger?.warning("Stage 4-half 取り込み失敗: code=\(code)")
            continue
        }
        try await withDbRetry(
            logger: logger, context: "code=\(code)", onRetry: { unhealthyRetries += 1 }
        ) {
            try await storeCompanyHalfFinancials(
                existing: existing, code: code, years: years, response: response,
                highWater: highWater, db: db)
        }
        stored += 1
    }

    return Stage4IngestSummary(
        attempted: attempted, stored: stored, failed: failed, skipped: skipped)
}

/// 計算済み半期サマリを company_half_financials へ書き込む（既存行があれば更新、無ければ作成）。
func storeCompanyHalfFinancials(
    existing: CompanyHalfFinancials?, code: String, years: Int,
    response: HalfFinancialsResponse, highWater: String?, db: Database
) async throws {
    if let row = existing {
        row.response = response
        row.cacheVersion = companyHalfFinancialsCacheVersion
        row.requestedYears = years
        row.highWater = highWater
        try await row.update(on: db)
    } else {
        let model = CompanyHalfFinancials()
        model.id = code
        model.response = response
        model.cacheVersion = companyHalfFinancialsCacheVersion
        model.requestedYears = years
        model.highWater = highWater
        try await model.create(on: db)
    }
}

// MARK: - read 経路（REST half-financials）

/// 格納済み半期 Stage 4 結果を code で引き、read 床（`companyHalfFinancialsMinServableVersion`）以上 &
/// 要求年数を満たすなら years に縮めた JSON を返す。
/// 無い・床未満・年数不足なら nil（呼び出し側は 404 を返す。ライブ計算へはフォールバックしない）。
///
/// 要求年数は半期算出上限（`Api.halfMaxYears`）へクランプする。半期はこの年数までしか作れず
/// 格納（`stage4HalfIngestYears`）もそこで頭打ちのため、上限超の要求でも上限ぶんを warm read で返す。
/// クランプしないと CLI 既定（`analyzeDefaultYears`=6 > 5）が常に guard を外し DB を空振りする。
func loadStoredHalfFinancials(code: String, years: Int, db: Database) async throws -> [String: Any]? {
    let effectiveYears = min(years, Api.halfMaxYears)
    guard effectiveYears > 0,
        let row = try await CompanyHalfFinancials.find(code, on: db),
        isServableCompanyHalfFinancialsCacheVersion(row.cacheVersion),
        row.requestedYears >= effectiveYears
    else { return nil }
    return row.response.trimmed(toYears: effectiveYears).jsonObject()
}
