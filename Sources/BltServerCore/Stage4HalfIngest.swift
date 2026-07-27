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

/// Stage 4-half 取り込み結果のサマリ。`notApplicable`（半期報告書未提出等、設計通り）を
/// `failed`（抽出できず要調査）と分けて数える点が通期 Stage 4 の `Stage4IngestSummary` と異なる
/// （issue #73 フォローアップ）。
public struct Stage4HalfIngestSummary: Sendable, Equatable {
    /// 計算を試みた企業数（skip を除く。notApplicable も含む＝実際に compute を呼んだ数）。
    public let attempted: Int
    /// 計算・格納に成功した企業数。
    public let stored: Int
    /// 書類はあるが抽出できず失敗した企業数（要調査）。
    public let failed: Int
    /// 半期報告書が未提出等、計算対象外だった企業数（設計通り・failed に含めない）。
    public let notApplicable: Int
    /// 既に現行バージョン・十分な年数で計算済みのためスキップした企業数。
    public let skipped: Int
}

/// 証券コードを受けて半期財務サマリを返す計算器（成功／対象外／失敗を区別する）。
/// 本番は `context.computeHalfFinancials`、テストはフェイクを注入する。
public typealias HalfFinancialsComputer = @Sendable (String) async -> HalfFinancialsComputeResult

/// edinet_documents の企業（証券コード）を走査し、未計算 or バージョン不一致／年数不足のものを計算・格納する。
/// `limit` は新規計算件数の上限（計算が重いためバッチ実行用）。通期 Stage 4 と同ロジック。
/// `listedCodes` を渡すと候補をその集合に絞る（上場廃止・外国法人等、二度と成功しない企業への
/// 無駄なリトライを避ける。`nil` は絞り込みなし＝従来どおり全企業）。
/// `explicitCodes` を渡すと候補をその集合に絞る（`--codes` 手動指定。`nil` は絞り込みなし）。
/// `priorityCodes` に含まれる企業は候補の中で先頭へ寄せる（対象選定ではなく処理順序のみ。空集合は無効化）。
func runStage4HalfIngest(
    db: Database, years: Int, limit: Int?, listedCodes: Set<String>? = nil,
    explicitCodes: Set<String>? = nil, priorityCodes: Set<String> = [], logger: Logger? = nil,
    compute: HalfFinancialsComputer
) async throws -> Stage4HalfIngestSummary {
    let (allCodes, highWaterMap) = try await distinctCompanyCodesWithHighWater(
        db: db, docTypes: Api.stage4HalfFreshnessDocTypes, logger: logger)
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
        if row.highWater != highWater {
            staleHighWater.append((code, highWater))
        } else if row.requestedYears < years {
            staleYears.append((code, highWater))
        } else if row.cacheVersion != companyHalfFinancialsCacheVersion {
            staleVersion.append((code, highWater))
        } else {
            skipped += 1
        }
    }
    let candidates = prioritized(
        interleaved([missing, staleHighWater, staleYears, staleVersion]), codeOf: \.code,
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
        switch await compute(code) {
        case .success(let response):
            try await withDbRetry(
                logger: logger, context: "code=\(code)", onRetry: { unhealthyRetries += 1 }
            ) {
                try await storeCompanyHalfFinancials(
                    existing: existing, code: code, years: years, response: response,
                    highWater: highWater, db: db)
            }
            stored += 1
        case .notApplicable:
            // 半期報告書未提出等、設計通りの対象外。プレースホルダ行（periods 空）を保存し、
            // 次回 ingest で highWater 一致のまま無駄な再試行を繰り返さないようにする
            // （読み取り経路 loadStoredHalfFinancials/loadStoredHalfAnalysis は periods 空を検出し
            // 404 を維持する。annual 側 Stage4Ingest.swift の notApplicable と同型、issue #86 派生）。
            // ノイズになるため warning ログは出さない。
            try await withDbRetry(
                logger: logger, context: "code=\(code)", onRetry: { unhealthyRetries += 1 }
            ) {
                try await storeCompanyHalfFinancials(
                    existing: existing, code: code, years: years,
                    response: .notApplicablePlaceholder(code: code), highWater: highWater, db: db)
            }
            notApplicable += 1
        case .failed:
            failed += 1
            logger?.warning("Stage 4-half 取り込み失敗: code=\(code)")
        }
    }

    return Stage4HalfIngestSummary(
        attempted: attempted, stored: stored, failed: failed, notApplicable: notApplicable,
        skipped: skipped)
}

/// 計算済み半期サマリを company_half_financials へ書き込む（既存行があれば更新、無ければ作成）。
func storeCompanyHalfFinancials(
    existing: CompanyHalfFinancials?, code: String, years: Int,
    response: HalfFinancialsResponse, highWater: String?, db: Database
) async throws {
    let applyFields: (CompanyHalfFinancials) -> Void = { row in
        row.response = response
        row.cacheVersion = companyHalfFinancialsCacheVersion
        row.requestedYears = years
        row.highWater = highWater
    }
    if let row = existing {
        applyFields(row)
        try await row.update(on: db)
    } else {
        let model = CompanyHalfFinancials()
        model.id = code
        applyFields(model)
        try await createIdempotently(
            create: { try await model.create(on: db) },
            recover: {
                guard let recovered = try await CompanyHalfFinancials.find(code, on: db) else { return false }
                applyFields(recovered)
                try await recovered.update(on: db)
                return true
            }
        )
    }
}

// MARK: - servable/unservable 集計

/// `cache_version` のみを対象にした軽量射影（`response` の JSONB を転送しない）。
/// company_half_financials 全件の servable/unservable 集計用（通期 Stage 4 と同型）。
final class CompanyHalfFinancialsCacheVersionOnly: Model, @unchecked Sendable {
    static let schema = CompanyHalfFinancials.schema

    @ID(custom: "code", generatedBy: .user)
    var id: String?

    @Field(key: "cache_version")
    var cacheVersion: String

    init() {}
}

/// company_half_financials 全件を read 床（`companyHalfFinancialsMinServableVersion`）で集計する。
/// ingest サマリログに DB 全体のカバレッジを添えるため、`response` を転送しない軽量クエリで行う。
func countServableCompanyHalfFinancials(db: Database) async throws -> (servable: Int, unservable: Int) {
    let versions = try await CompanyHalfFinancialsCacheVersionOnly.query(on: db).all()
        .map(\.cacheVersion)
    let servable = versions.filter(isServableCompanyHalfFinancialsCacheVersion).count
    return (servable, versions.count - servable)
}

// MARK: - read 経路（REST half-financials）

/// 格納済み半期 Stage 4 結果を code で引き、read 床（`companyHalfFinancialsMinServableVersion`）以上 &
/// 要求年数を満たすなら years に縮めた JSON を返す。
/// 無い・床未満・年数不足なら nil（呼び出し側は 404 を返す。ライブ計算へはフォールバックしない）。
/// `periods` 空（半期報告書未提出の notApplicable プレースホルダ）も nil（404）とする。
///
/// 要求年数は半期算出上限（`Api.halfMaxYears`）へクランプする。半期はこの年数までしか作れず
/// 格納（`stage4HalfIngestYears`）もそこで頭打ちのため、上限超の要求でも上限ぶんを warm read で返す。
/// クランプしないと CLI 既定（`analyzeDefaultYears`=6 > 5）が常に guard を外し DB を空振りする。
func loadStoredHalfFinancials(code: String, years: Int, db: Database) async throws -> [String: Any]? {
    let effectiveYears = min(years, Api.halfMaxYears)
    guard effectiveYears > 0,
        let row = try await CompanyHalfFinancials.find(code, on: db),
        isServableCompanyHalfFinancialsCacheVersion(row.cacheVersion),
        row.requestedYears >= effectiveYears,
        row.response.periodCount > 0
    else { return nil }
    return row.response.trimmed(toYears: effectiveYears).summaryJsonObject()
}

/// 格納済み半期 Stage 4 結果を code で引き、増減分解フィールド（`docs/feature-tiers.md` の Analyze）を
/// 含めた JSON を返す。読み取り床・年数要件・クランプは `loadStoredHalfFinancials` と同一
/// （同じ格納行を使う。新規テーブル・cache_version は導入しない）。
func loadStoredHalfAnalysis(code: String, years: Int, db: Database) async throws -> [String: Any]? {
    let effectiveYears = min(years, Api.halfMaxYears)
    guard effectiveYears > 0,
        let row = try await CompanyHalfFinancials.find(code, on: db),
        isServableCompanyHalfFinancialsCacheVersion(row.cacheVersion),
        row.requestedYears >= effectiveYears,
        row.response.periodCount > 0
    else { return nil }
    return row.response.trimmed(toYears: effectiveYears).analysisJsonObject()
}
