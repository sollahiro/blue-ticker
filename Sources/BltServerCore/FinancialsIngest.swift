// 財務取り込み: edinet_documents に存在する企業（証券コード）について財務サマリを計算し、
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

/// 財務取り込み結果のサマリ。`notApplicable`（有価証券報告書未提出等、設計通り）を
/// `failed`（抽出できず要調査）と分けて数える（issue #86）。
public struct FinancialsIngestSummary: Sendable, Equatable {
    /// 計算を試みた企業数（skip を除く。notApplicable も含む＝実際に compute を呼んだ数）。
    public let attempted: Int
    /// 計算・格納に成功した企業数。
    public let stored: Int
    /// 書類はあるが抽出できず失敗した企業数（要調査）。縮小ガードの保留（`refused`）は含めない。
    public let failed: Int
    /// 計算はできたが、最新 FY を失う上書き（ローカル EDINET インデックスが最新有報を欠く）として
    /// 格納を保留した企業数。行と high_water は据え置き、次回再試行される。
    public let refused: Int
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
func runFinancialsIngest(
    db: Database, years: Int, limit: Int?, listedCodes: Set<String>? = nil,
    explicitCodes: Set<String>? = nil, priorityCodes: Set<String> = [],
    forceCodes: Set<String> = [], logger: Logger? = nil,
    compute: FinancialsComputer
) async throws -> FinancialsIngestSummary {
    let (allCodes, highWaterMap, newestAnnualMap) = try await distinctCompanyCodesWithHighWater(
        db: db, docTypes: Api.financialsFreshnessDocTypes, logger: logger)
    let listedFiltered = listedCodes.map { listed in allCodes.filter { listed.contains($0) } } ?? allCodes
    let codes = explicitCodes.map { explicit in listedFiltered.filter { explicit.contains($0) } } ?? listedFiltered

    var attempted = 0
    var stored = 0
    var failed = 0
    var refused = 0
    var notApplicable = 0
    var skipped = 0
    var unhealthyRetries = 0
    var missing: [(code: String, highWater: String?)] = []
    var staleVersion: [(code: String, highWater: String?)] = []
    var staleYears: [(code: String, highWater: String?)] = []
    var staleHighWater: [(code: String, highWater: String?)] = []

    let classifyRows = try await withDbRetry(
        logger: logger, context: "財務取り込み 分類", onRetry: { unhealthyRetries += 1 }
    ) {
        try await CompanyFinancialsCacheVersionOnly.query(on: db).all()
    }
    let classifyIndex = ingestIndexByID(classifyRows) { $0.id }

    for code in codes {
        let highWater = highWaterMap[code]
        if forceCodes.contains(code) {
            missing.append((code, highWater))
            continue
        }
        guard let row = classifyIndex[code] else {
            missing.append((code, highWater))
            continue
        }
        if row.highWater != highWater {
            staleHighWater.append((code, highWater))
        } else if row.requestedYears < years {
            staleYears.append((code, highWater))
        } else if row.cacheVersion != companyFinancialsCacheVersion
            || !isCurrentFinancialsAssemblyFingerprint(row.assemblyFingerprint)
        {
            staleVersion.append((code, highWater))
        } else {
            skipped += 1
        }
    }
    let missingCodes = Set(missing.map(\.code))
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
                "DB接続が不安定なため 財務取り込み を中断します(リトライ\(unhealthyRetries)回・残り\(candidates.count - attempted)社は次回スケジュールで再試行)"
            )
            break
        }
        let existing: CompanyFinancials?
        // force 指定は行があっても missing に入るため、縮小ガード用に既存行を読む（--codes 等の少数のみ）。
        if missingCodes.contains(code) && !forceCodes.contains(code) {
            existing = nil
        } else {
            existing = try await withDbRetry(
                logger: logger, context: "code=\(code)", onRetry: { unhealthyRetries += 1 }
            ) {
                try await CompanyFinancials.find(code, on: db)
            }
        }
        // force 指定（--doc-ids 由来の codes・override 対象）は行が現行（cache_version・high_water・
        // assembly_fingerprint 一致）でも skip せず必ず再計算・格納する。指定したのに黙って skip されると
        // 再取り込みの意図が反映されない（--doc-ids 100 件で 14 社が skip された）。縮小ガードは下で通常どおり効く。
        if !forceCodes.contains(code), let row = existing,
            row.cacheVersion == companyFinancialsCacheVersion,
            row.requestedYears >= years, row.highWater == highWater,
            isCurrentFinancialsAssemblyFingerprint(row.assemblyFingerprint)
        {
            skipped += 1
            continue
        }
        if let lim = limit, attempted >= lim { break }
        attempted += 1
        let computed = await compute(code)
        // 計算結果の最新 fy_end が格納済み行や DB の最新有報より古い（＝ローカル EDINET 年次インデックスが
        // 最新有報を欠く）なら書かない。行全体を上書きし high_water まで進めると、欠落した FY が
        // 以後 skip され続ける（2026-09-18 提出分の FY2026 が 12 社で消えた）。refused として数え、
        // 行と high_water を据え置くので次回 ingest で再試行される。
        // notApplicable は、years を持つ格納行があり DB に格納最新 FY 以上の有報があるときだけ保留する
        // （603A 型: 遅れたインデックスで years 行を空プレースホルダへ置き換えない）。格納 years が無い
        // 正当な対象外社は従来どおりプレースホルダを書く（毎回再計算するループにしない）。
        let refusal: FinancialsStoreRefusal?
        switch computed {
        case .success(let response):
            refusal = financialsStoreRefusal(
                computedYears: response, stored: existing?.response, newestAnnual: newestAnnualMap[code])
        case .notApplicable:
            refusal = financialsStoreRefusal(
                computedYears: nil, stored: existing?.response, newestAnnual: newestAnnualMap[code])
        case .failed:
            refusal = nil
        }
        if let refusal {
            refused += 1
            logger?.warning(
                "財務取り込み保留: code=\(code) local EDINET index lacks \(refusal.lacking)",
                metadata: refusal.logMetadata(code: code))
            continue
        }
        switch computed {
        case .success(let response):
            try await withDbRetry(
                logger: logger, context: "code=\(code)", onRetry: { unhealthyRetries += 1 }
            ) {
                try await storeCompanyFinancials(
                    existing: try await CompanyFinancials.find(code, on: db),
                    code: code, years: years, response: response,
                    highWater: highWater, db: db)
            }
            stored += 1
            await refreshScreenIndexAfterFinancials(code: code, response: response, db: db, logger: logger)
        case .notApplicable:
            // 有価証券報告書未提出等、設計通りの対象外。プレースホルダ行（years 空）を保存し、
            // 次回 ingest で highWater 一致のまま無駄な再試行を繰り返さないようにする
            // （読み取り経路 loadStoredFinancials/loadStoredAnalysis は years 空を検出し 404 を維持する）。
            // ノイズになるため warning ログは出さない。
            try await withDbRetry(
                logger: logger, context: "code=\(code)", onRetry: { unhealthyRetries += 1 }
            ) {
                try await storeCompanyFinancials(
                    existing: try await CompanyFinancials.find(code, on: db),
                    code: code, years: years,
                    response: .notApplicablePlaceholder(code: code), highWater: highWater, db: db)
            }
            notApplicable += 1
            await refreshScreenIndexAfterFinancials(
                code: code, response: .notApplicablePlaceholder(code: code), db: db, logger: logger)
        case .failed:
            failed += 1
            logger?.warning("財務取り込み失敗: code=\(code)")
        }
    }

    await backfillScreenIndexForServableFinancials(db: db, logger: logger)

    return FinancialsIngestSummary(
        attempted: attempted, stored: stored, failed: failed, refused: refused,
        notApplicable: notApplicable, skipped: skipped)
}

/// 発行体の最新有報（会社開示府令の 120・period_end あり）。財務取り込みの縮小ガード用。
struct NewestAnnualFiling: Sendable, Equatable {
    let periodEnd: String
    let docID: String
}

/// 財務取り込みの格納保留（縮小ガード）。自動上書き（override）はしない。恒久的に続く保留
/// （最新有報の XBRL が取れない、別 EDINET コードが同じ 4 桁コードに写る等）を構造化ログで追えるようにする。
struct FinancialsStoreRefusal: Sendable, Equatable {
    enum Reason: String, Sendable {
        /// 計算結果の最新 fy_end < DB の最新有報（会社開示 120）period_end。
        case olderThanDatabaseAnnual = "older_than_db_annual"
        /// 計算結果の最新 fy_end < 格納済み行の最新 fy_end。
        case olderThanStoredRow = "older_than_stored_row"
        /// notApplicable（years 空）だが、格納行に years があり DB に格納最新 FY 以上の有報がある。
        case placeholderOverStoredYears = "placeholder_over_stored_years"
    }

    let reason: Reason
    /// 欠けている書類（DB の最新有報 docID、無ければ格納行の最新年の doc_id）。
    let missingDocID: String?
    let computedNewestFyEnd: String?
    let storedNewestFyEnd: String?
    let databaseNewestPeriodEnd: String?

    /// ログ本文の `local EDINET index lacks <doc>` に入れる値。
    var lacking: String { missingDocID ?? "fy_end=\(storedNewestFyEnd ?? "")" }

    func logMetadata(code: String) -> Logger.Metadata {
        var metadata: Logger.Metadata = [
            "event": "financials_store_refused",
            "code": .string(code),
            "reason": .string(reason.rawValue),
        ]
        if let missingDocID { metadata["doc_id"] = .string(missingDocID) }
        if let computedNewestFyEnd { metadata["computed_newest_fy_end"] = .string(computedNewestFyEnd) }
        if let storedNewestFyEnd { metadata["stored_newest_fy_end"] = .string(storedNewestFyEnd) }
        if let databaseNewestPeriodEnd { metadata["db_newest_period_end"] = .string(databaseNewestPeriodEnd) }
        return metadata
    }
}

/// 格納してよいかを判定する。nil なら格納してよい。
/// - `computedYears` が success の応答: 最新 fy_end が格納済み行の最新 fy_end または DB の最新有報
///   period_end より古ければ保留。
/// - `computedYears == nil`（notApplicable プレースホルダ）: 格納行に years があり、かつ DB に格納最新 FY
///   以上の会社開示 120 があるときだけ保留。格納 years が無ければ従来どおり格納してよい。
func financialsStoreRefusal(
    computedYears: FinancialsResponse?, stored: FinancialsResponse?, newestAnnual: NewestAnnualFiling?
) -> FinancialsStoreRefusal? {
    let storedNewest = stored?.newestFiscalYearEnd
    guard let computed = computedYears else {
        guard let storedNewest, let annual = newestAnnual, annual.periodEnd >= storedNewest.fyEnd
        else { return nil }
        return FinancialsStoreRefusal(
            reason: .placeholderOverStoredYears, missingDocID: annual.docID, computedNewestFyEnd: nil,
            storedNewestFyEnd: storedNewest.fyEnd, databaseNewestPeriodEnd: annual.periodEnd)
    }
    let computedNewest = computed.newestFiscalYearEnd?.fyEnd
    if let annual = newestAnnual, (computedNewest ?? "") < annual.periodEnd {
        return FinancialsStoreRefusal(
            reason: .olderThanDatabaseAnnual, missingDocID: annual.docID,
            computedNewestFyEnd: computedNewest, storedNewestFyEnd: storedNewest?.fyEnd,
            databaseNewestPeriodEnd: annual.periodEnd)
    }
    if let storedNewest, (computedNewest ?? "") < storedNewest.fyEnd {
        return FinancialsStoreRefusal(
            reason: .olderThanStoredRow, missingDocID: storedNewest.docID,
            computedNewestFyEnd: computedNewest, storedNewestFyEnd: storedNewest.fyEnd,
            databaseNewestPeriodEnd: newestAnnual?.periodEnd)
    }
    return nil
}

/// edinet_documents の secCode（5 桁・末尾 0）から 4 桁コードを導出し、重複排除して返す。
/// secCode が無い／非上場（末尾 0 でない・桁数不一致）は、master の EDINETコードで
/// 上場発行体に写せるときだけ対象にする（提出当日の secCode 欠落対策）。
/// コード列挙は財務行の対象社集合を変えないため全 doc から行うが、high-water は
/// `docTypes` に含まれる **かつ会社開示府令(010)** の doc のみで `code -> max(submitDateTime)`
/// （辞書順）を構築する。信託受益証券等の 120 では通期再計算を起こさない。
/// 該当種別の書類が無い社は high-water map に現れない（nil 扱い）。
/// `newestAnnual` は code ごとの最新有報（会社開示府令の 120 で period_end 最大。縮小ガード用）。
func distinctCompanyCodesWithHighWater(
    db: Database, docTypes: Set<String>, logger: Logger? = nil
) async throws -> (codes: [String], highWater: [String: String], newestAnnual: [String: NewestAnnualFiling]) {
    let listedSecByEdinet = await listedSecCodeByEdinetCode()
    let issuers = try await withDbRetry(logger: logger, context: "全書類一覧") {
        try await issuerHighWaterRows(db: db, docTypes: docTypes)
    }
    var seen = Set<String>()
    var codes: [String] = []
    var highWater: [String: String] = [:]
    var newestAnnual: [String: NewestAnnualFiling] = [:]
    for issuer in issuers {
        guard let code = listedIssuerCode(
            secCode: issuer.secCode, edinetCode: issuer.edinetCode,
            listedSecCodeByEdinetCode: listedSecByEdinet)
        else { continue }
        if seen.insert(code).inserted { codes.append(code) }
        if let water = issuer.highWater, water > (highWater[code] ?? "") {
            highWater[code] = water
        }
        if let packed = issuer.newestAnnual, let sep = packed.firstIndex(of: "|") {
            let filing = NewestAnnualFiling(
                periodEnd: String(packed[..<sep]), docID: String(packed[packed.index(after: sep)...]))
            if filing.periodEnd > (newestAnnual[code]?.periodEnd ?? "") { newestAnnual[code] = filing }
        }
    }
    return (codes, highWater, newestAnnual)
}

/// 計算済みサマリを company_financials へ書き込む（既存行があれば更新、無ければ作成）。
/// cache_version に現行 companyFinancialsCacheVersion、requested_years に計算年数、
/// high_water に消費書類集合の現在の max(submitDateTime)、
/// assembly_fingerprint に現行正本組立指紋を埋め込む。
func storeCompanyFinancials(
    existing: CompanyFinancials?, code: String, years: Int,
    response: FinancialsResponse, highWater: String?, db: Database
) async throws {
    let applyFields: (CompanyFinancials) -> Void = { row in
        row.response = response
        row.cacheVersion = companyFinancialsCacheVersion
        row.requestedYears = years
        row.highWater = highWater
        row.assemblyFingerprint = financialsAssemblyFingerprint()
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

/// `cache_version` / 年数 / high-water / 組立指紋を対象にした軽量射影（`response` の JSONB を転送しない）。
/// company_financials 全件の servable/unservable 集計用（`EdinetMasterSnapshotUpdatedAt` と同型）。
final class CompanyFinancialsCacheVersionOnly: Model, @unchecked Sendable {
    static let schema = CompanyFinancials.schema

    @ID(custom: "code", generatedBy: .user)
    var id: String?

    @Field(key: "cache_version")
    var cacheVersion: String

    @Field(key: "requested_years")
    var requestedYears: Int

    @OptionalField(key: "high_water")
    var highWater: String?

    @OptionalField(key: "assembly_fingerprint")
    var assemblyFingerprint: String?

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

/// 格納済み 財務取り込み 結果を code で引き、read 床以上 & 要求年数を満たすなら years に縮めた JSON を返す。
/// 床は `companyFinancialsMinServableVersion`（明示定数。現行版との完全一致ではない）。
/// 無い・床未満・年数不足なら nil（呼び出し側は 404。ライブ計算へはフォールバックしない）。
/// `years` 空（有価証券報告書未提出の notApplicable プレースホルダ、issue #86）も nil（404）とする。
/// `fields` は `years[]` 要素の射影（BLT-57）。nil なら従来どおり全キー。値・年数は変えない。
func loadStoredFinancials(
    code: String, years: Int, fields: Set<String>? = nil, db: Database
) async throws -> [String: Any]? {
    // years <= 0 は無効要求として nil（呼び出し側 404）。空 years の 200 を返さない。
    guard years > 0,
        let row = try await CompanyFinancials.find(code, on: db),
        isServableCompanyFinancialsCacheVersion(row.cacheVersion),
        row.requestedYears >= years,
        row.response.yearCount > 0
    else { return nil }
    return row.response.trimmed(toYears: years).summaryJsonObject(fields: fields)
}

/// 格納済み 財務取り込み 結果を code で引き、増減分解フィールド（`docs/financials-summary-separation.md` の Waterfall）を
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
