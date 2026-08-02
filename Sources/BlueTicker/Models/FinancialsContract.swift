// financials API の公開契約（flatten 形）。サーバーとクライアントで共有する単一の Codable 型。
//
// 設計意図:
// - サーバー（財務取り込み ingest の computeFinancials → DB 格納 → read で jsonObject()）は
//   この型から JSON を生成し、remote CLI（RemoteAPIClient）は同じ型でデコードして MetricsResult に復元する。
//   キー定義が 1 か所（CodingKeys）に集約され、契約のドリフトを防ぐ（「統一」）。
// - 内部モデル（MetricsResult/RawData/CalculatedData）は直シリアライズせず、ここで
//   公開用フラット形（snake_case）へ写像する（公開 API を内部モデルから疎結合に保つ）。
// - 出力は「全キーが存在する（欠落値は null）」を維持する（既存契約の互換性）。
//   nil の Optional を JSONEncoder は省略するため、jsonObject() で CodingKeys.allCases を
//   使って null を補完する。
//
// Foundation のみ依存（NIO/Vapor 非依存）。サーバー・CLI 双方から使う。

import Foundation

/// 財務取り込み（通期）の計算結果。「対象外」（有価証券報告書が未提出、新規上場等で設計通り・再提出待ち）と
/// 「失敗」（書類はあるが抽出できない、要調査）を区別する（issue #86）。
/// ingest サマリで前者を failed カウントへ混入させないために使う。
public enum FinancialsComputeResult: Sendable {
    case success(FinancialsResponse)
    case notApplicable
    case failed
}

/// Neon 財務取り込み キャッシュ（`company_financials.cache_version`）の計算バージョン。
/// `blueTickerVersion` とは独立し、財務計算ロジック（`computeFinancials` / `Analysis` 抽出器）
/// または本契約型（`FinancialsResponse` / `FinancialsYear`）の意味を変えたときのみバンプする。
/// グローバルバージョンに連動させないことで、月内 Micro バンプで高コストな全社再計算
/// （XBRL 再ダウンロード＋HTML 依存抽出の再実行）を走らせない（XBRL 数値 RAW の `xbrlFactsCacheVersion` と同思想）。
///
/// PR #27（6836 売掛金の企業拡張タグ対応）はこのバージョンをバンプせず fin-v3 のまま合流した。
/// 抽出ロジック変更の反映（既存キャッシュ済み行の再計算）は、他の同種修正が貯まってから
/// まとめて fin-v4 へバンプし、全社再 ingest を一度に走らせる方針のため意図的に保留している。
public let companyFinancialsCacheVersion = "fin-v4"

/// financials read（REST）が 200 を返す最低計算バージョン番号（`fin-vN` の N）。
/// **明示指定**であり、「現行から 2 つ前」のような機械オフセットではない。人手で上げる。
/// ingest の stale 判定・書き込みは常に `companyFinancialsCacheVersion`。床未満の行は 404。
/// 床の引き上げは、該当旧版の stale 消化が終わってから行う（引き上げ後に servable 穴を作らない）。
/// 不変条件: `companyFinancialsMinServableVersion` ≤ 現行 `fin-vN` の N。
public let companyFinancialsMinServableVersion = 4

/// `fin-vN` 形式から世代番号 N を取り出す。パース不能なら nil（非 servable 扱い）。
public func companyFinancialsCacheVersionNumber(_ version: String) -> Int? {
    guard version.hasPrefix("fin-v") else { return nil }
    let suffix = version.dropFirst("fin-v".count)
    guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber), let n = Int(suffix) else { return nil }
    return n
}

/// 格納行の `cache_version` が read 床以上か。文字列辞書順比較は使わない（`fin-v10` 対策）。
public func isServableCompanyFinancialsCacheVersion(_ version: String) -> Bool {
    guard let n = companyFinancialsCacheVersionNumber(version) else { return false }
    return n >= companyFinancialsMinServableVersion
}

// MARK: - 年度エントリ（フラット形）

struct FinancialsYear: Codable, Sendable {
    var fyEnd: String?
    var financialPeriod: String?
    var curPerType: String?
    var docId: String?
    var salesLabel: String?
    var grossProfitLabel: String?
    var opLabel: String?

    var sales: Double?
    var grossProfit: Double?
    var grossProfitMargin: Double?
    var sga: Double?
    var operatingProfit: Double?
    var operatingMargin: Double?
    var nopat: Double?
    var netProfit: Double?
    var effectiveTaxRate: Double?

    var roe: Double?
    var roic: Double?
    var nopatMargin: Double?
    var investedCapitalTurnover: Double?
    var interestBearingDebt: Double?
    var interestExpense: Double?

    var totalAssets: Double?
    var currentAssets: Double?
    var nonCurrentAssets: Double?
    var ppeTotal: Double?
    var currentLiabilities: Double?
    var nonCurrentLiabilities: Double?
    var netAssets: Double?
    var accountsReceivable: Double?
    var inventory: Double?
    var accountsPayable: Double?
    var workingCapital: Double?

    var cashEquivalents: Double?
    var netCash: Double?
    var netDe: Double?
    var cfo: Double?
    var cfi: Double?
    var cfc: Double?
    var capex: Double?
    var buyback: Double?
    var rd: Double?
    var cfTreasuryStock: Double?
    var dividendSs: Double?
    var dividendPaidCf: Double?

    var eps: Double?
    var issuedShares: Double?
    var employees: Int?

    // 増減分析（事業利益・ROIC・ROE）
    var businessProfit: Double?
    var businessProfitMargin: Double?
    var businessProfitChange: Double?
    var salesChangeImpact: Double?
    var grossMarginChangeImpact: Double?
    var sgaChangeImpact: Double?
    var netMargin: Double?
    var assetTurnover: Double?
    var financialLeverage: Double?
    var roicDelta: Double?
    var roicMarginEffect: Double?
    var roicTurnoverEffect: Double?
    var roeDelta: Double?
    var roeNetMarginEffect: Double?
    var roeAssetTurnoverEffect: Double?
    var roeLeverageEffect: Double?

    // 運転資本・CCC
    var dso: Double?
    var dio: Double?
    var dpo: Double?
    var ccc: Double?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case fyEnd = "fy_end"
        case financialPeriod = "financial_period"
        case curPerType = "cur_per_type"
        case docId = "doc_id"
        case salesLabel = "sales_label"
        case grossProfitLabel = "gross_profit_label"
        case opLabel = "op_label"
        case sales
        case grossProfit = "gross_profit"
        case grossProfitMargin = "gross_profit_margin"
        case sga
        case operatingProfit = "operating_profit"
        case operatingMargin = "operating_margin"
        case nopat
        case netProfit = "net_profit"
        case effectiveTaxRate = "effective_tax_rate"
        case roe
        case roic
        case nopatMargin = "nopat_margin"
        case investedCapitalTurnover = "invested_capital_turnover"
        case interestBearingDebt = "interest_bearing_debt"
        case interestExpense = "interest_expense"
        case totalAssets = "total_assets"
        case currentAssets = "current_assets"
        case nonCurrentAssets = "non_current_assets"
        case ppeTotal = "ppe_total"
        case currentLiabilities = "current_liabilities"
        case nonCurrentLiabilities = "non_current_liabilities"
        case netAssets = "net_assets"
        case accountsReceivable = "accounts_receivable"
        case inventory
        case accountsPayable = "accounts_payable"
        case workingCapital = "working_capital"
        case cashEquivalents = "cash_equivalents"
        case netCash = "net_cash"
        case netDe = "net_de"
        case cfo
        case cfi
        case cfc
        case capex
        case buyback
        case rd
        case cfTreasuryStock = "cf_treasury_stock"
        case dividendSs = "dividend_ss"
        case dividendPaidCf = "dividend_paid_cf"
        case eps
        case issuedShares = "issued_shares"
        case employees
        case businessProfit = "business_profit"
        case businessProfitMargin = "business_profit_margin"
        case businessProfitChange = "business_profit_change"
        case salesChangeImpact = "sales_change_impact"
        case grossMarginChangeImpact = "gross_margin_change_impact"
        case sgaChangeImpact = "sga_change_impact"
        case netMargin = "net_margin"
        case assetTurnover = "asset_turnover"
        case financialLeverage = "financial_leverage"
        case roicDelta = "roic_delta"
        case roicMarginEffect = "roic_margin_effect"
        case roicTurnoverEffect = "roic_turnover_effect"
        case roeDelta = "roe_delta"
        case roeNetMarginEffect = "roe_net_margin_effect"
        case roeAssetTurnoverEffect = "roe_asset_turnover_effect"
        case roeLeverageEffect = "roe_leverage_effect"
        case dso
        case dio
        case dpo
        case ccc
    }
}

extension FinancialsYear {
    /// 内部モデル（YearEntry）→ 公開フラット形。サーバー側で使う。
    init(_ entry: YearEntry) {
        let raw = entry.rawData
        let calc = entry.calculatedData
        fyEnd = entry.fyEnd
        financialPeriod = entry.financialPeriod
        curPerType = raw.curPerType
        docId = calc.docID
        salesLabel = raw.salesLabel
        grossProfitLabel = calc.grossProfitLabel
        opLabel = calc.opLabel

        sales = raw.sales
        grossProfit = calc.grossProfit
        grossProfitMargin = calc.grossProfitMargin
        sga = calc.sellingGeneralAdministrativeExpenses
        operatingProfit = raw.op
        operatingMargin = calc.operatingMargin
        nopat = calc.nopat
        netProfit = raw.np
        effectiveTaxRate = calc.effectiveTaxRate

        roe = calc.roe
        roic = calc.roic
        nopatMargin = calc.nopatMargin
        investedCapitalTurnover = calc.investedCapitalTurnover
        interestBearingDebt = calc.interestBearingDebt
        interestExpense = calc.interestExpense

        totalAssets = calc.totalAssets
        currentAssets = calc.currentAssets
        nonCurrentAssets = calc.nonCurrentAssets
        ppeTotal = calc.ppeTotal
        currentLiabilities = calc.currentLiabilities
        nonCurrentLiabilities = calc.nonCurrentLiabilities
        netAssets = calc.netAssets
        accountsReceivable = calc.accountsReceivable
        inventory = calc.inventory
        accountsPayable = calc.accountsPayable
        workingCapital = calc.workingCapital

        cashEquivalents = raw.cashEq
        netCash = calc.netCash
        netDe = calc.netDE
        cfo = raw.cfo
        cfi = raw.cfi
        cfc = calc.cfc
        capex = raw.capex
        buyback = raw.buyback
        rd = raw.rd
        cfTreasuryStock = calc.cfTreasuryStock
        dividendSs = calc.dividendSS
        dividendPaidCf = calc.dividendPaidCF

        eps = raw.eps
        issuedShares = raw.shOutFY
        employees = calc.employees

        businessProfit = calc.businessProfit
        businessProfitMargin = calc.businessProfitMargin
        businessProfitChange = calc.businessProfitChange
        salesChangeImpact = calc.salesChangeImpact
        grossMarginChangeImpact = calc.grossMarginChangeImpact
        sgaChangeImpact = calc.sgaChangeImpact
        netMargin = calc.netMargin
        assetTurnover = calc.assetTurnover
        financialLeverage = calc.financialLeverage
        roicDelta = calc.roicDelta
        roicMarginEffect = calc.roicMarginEffect
        roicTurnoverEffect = calc.roicTurnoverEffect
        roeDelta = calc.roeDelta
        roeNetMarginEffect = calc.roeNetMarginEffect
        roeAssetTurnoverEffect = calc.roeAssetTurnoverEffect
        roeLeverageEffect = calc.roeLeverageEffect

        dso = calc.dso
        dio = calc.dio
        dpo = calc.dpo
        ccc = calc.ccc
    }

    /// 公開フラット形 → 内部モデル（YearEntry）。remote CLI が既存レンダラへ渡すために復元する。
    /// レンダラが参照するフィールドのみ詰める（その他は nil）。
    func toYearEntry() -> YearEntry {
        var raw = RawData.blank
        raw.curPerType = curPerType
        raw.salesLabel = salesLabel
        raw.sales = sales
        raw.op = operatingProfit
        raw.np = netProfit
        raw.cfo = cfo
        raw.cfi = cfi
        raw.capex = capex
        raw.buyback = buyback
        raw.rd = rd
        raw.eps = eps
        raw.shOutFY = issuedShares
        raw.cashEq = cashEquivalents

        var calc = CalculatedData.blank
        calc.docID = docId
        calc.grossProfit = grossProfit
        calc.grossProfitMargin = grossProfitMargin
        calc.grossProfitLabel = grossProfitLabel
        calc.sellingGeneralAdministrativeExpenses = sga
        calc.operatingMargin = operatingMargin
        calc.opLabel = opLabel
        calc.nopat = nopat
        calc.effectiveTaxRate = effectiveTaxRate
        calc.roe = roe
        calc.roic = roic
        calc.nopatMargin = nopatMargin
        calc.investedCapitalTurnover = investedCapitalTurnover
        calc.interestBearingDebt = interestBearingDebt
        calc.interestExpense = interestExpense
        calc.totalAssets = totalAssets
        calc.currentAssets = currentAssets
        calc.nonCurrentAssets = nonCurrentAssets
        calc.ppeTotal = ppeTotal
        calc.currentLiabilities = currentLiabilities
        calc.nonCurrentLiabilities = nonCurrentLiabilities
        calc.netAssets = netAssets
        calc.accountsReceivable = accountsReceivable
        calc.inventory = inventory
        calc.accountsPayable = accountsPayable
        calc.workingCapital = workingCapital
        calc.netCash = netCash
        calc.netDE = netDe
        calc.cfc = cfc
        calc.cfTreasuryStock = cfTreasuryStock
        calc.dividendSS = dividendSs
        calc.dividendPaidCF = dividendPaidCf
        calc.employees = employees
        calc.businessProfit = businessProfit
        calc.businessProfitMargin = businessProfitMargin
        calc.businessProfitChange = businessProfitChange
        calc.salesChangeImpact = salesChangeImpact
        calc.grossMarginChangeImpact = grossMarginChangeImpact
        calc.sgaChangeImpact = sgaChangeImpact
        calc.netMargin = netMargin
        calc.assetTurnover = assetTurnover
        calc.financialLeverage = financialLeverage
        calc.roicDelta = roicDelta
        calc.roicMarginEffect = roicMarginEffect
        calc.roicTurnoverEffect = roicTurnoverEffect
        calc.roeDelta = roeDelta
        calc.roeNetMarginEffect = roeNetMarginEffect
        calc.roeAssetTurnoverEffect = roeAssetTurnoverEffect
        calc.roeLeverageEffect = roeLeverageEffect
        calc.dso = dso
        calc.dio = dio
        calc.dpo = dpo
        calc.ccc = ccc

        return YearEntry(
            fyEnd: fyEnd,
            financialPeriod: financialPeriod ?? "",
            rawData: raw,
            calculatedData: calc
        )
    }

    /// 全キーを含む JSON オブジェクト（欠落値は null）。既存契約の「全キー存在」を維持する。
    func jsonObject() -> [String: Any] {
        var dict = encodeToDictionary(self)
        for key in CodingKeys.allCases where dict[key.rawValue] == nil {
            dict[key.rawValue] = NSNull()
        }
        return dict
    }

    /// Waterfall（`docs/feature-tiers.md`）専用の増減分解フィールド。Summary（financials）の応答からは
    /// これらを外す。値自体は 財務取り込み ingest で計算済みで DB には残したまま、read 応答でのみ絞り込む。
    /// 対象は Waterfall（増減分析）が使う前年差・要因分解・運転資本/CCC水準値。
    /// 注意: 「`SummaryRendering.levelMetrics` に無いフィールド」全般ではない
    /// （`eps`/`issuedShares`/`employees` 等はどちらの表示にも使われず対象外のまま）。
    static let analysisOnlyKeys: Set<String> = [
        "business_profit", "business_profit_margin",
        "business_profit_change", "sales_change_impact",
        "gross_margin_change_impact", "sga_change_impact",
        "net_margin", "asset_turnover", "financial_leverage",
        "roic_delta", "roic_margin_effect", "roic_turnover_effect",
        "roe_delta", "roe_net_margin_effect", "roe_asset_turnover_effect", "roe_leverage_effect",
        "working_capital", "dso", "dio", "dpo", "ccc",
    ]

    /// Summary（financials）応答用 JSON。`analysisOnlyKeys` を除いた水準値のみを返す。
    func summaryJsonObject() -> [String: Any] {
        var dict = jsonObject()
        for key in Self.analysisOnlyKeys { dict.removeValue(forKey: key) }
        return dict
    }

    /// Waterfall（waterfall）応答用 JSON。`jsonObject()` の全キーに加えて、CLI `ticker waterfall` の
    /// ④⑤ブロック（ネットキャッシュ差分・運転資本/CCC差分の要因分解）を `prior`（直前期。無ければ nil）
    /// との差分からその場で計算して追加する。DB には保存しない（read 時のみの投影）。
    func analysisJsonObject(prior: FinancialsYear?) -> [String: Any] {
        var dict = jsonObject()
        func delta(_ a: Double?, _ b: Double?) -> Any {
            guard let a, let b else { return NSNull() }
            return a - b
        }
        dict["net_cash_change"] = delta(netCash, prior?.netCash)
        dict["cash_change_impact"] = delta(cashEquivalents, prior?.cashEquivalents)
        dict["debt_change_impact"] = delta(prior?.interestBearingDebt, interestBearingDebt)
        dict["working_capital_change"] = delta(workingCapital, prior?.workingCapital)
        dict["accounts_receivable_change_impact"] = delta(accountsReceivable, prior?.accountsReceivable)
        dict["inventory_change_impact"] = delta(inventory, prior?.inventory)
        dict["accounts_payable_change_impact"] = delta(prior?.accountsPayable, accountsPayable)
        dict["ccc_change"] = delta(ccc, prior?.ccc)
        dict["dso_change_impact"] = delta(dso, prior?.dso)
        dict["dio_change_impact"] = delta(dio, prior?.dio)
        dict["dpo_change_impact"] = delta(prior?.dpo, dpo)
        return dict
    }
}

// MARK: - レスポンス（トップレベル封筒）

// public: BltServerCore（財務取り込み derived キャッシュ）がこの型を JSONB として保存・読込する。
// 内部メンバーは internal のまま（モジュール外からは Codable 経由でのみ扱う）。
public struct FinancialsResponse: Codable, Sendable {
    var schemaVersion: Int
    var code: String
    var name: String
    var sector: String
    var market: String
    var currency: String
    var unit: String
    var years: [FinancialsYear]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case code, name, sector, market, currency, unit, years
    }
}

extension FinancialsResponse {
    /// 内部モデル（MetricsResult）→ 公開契約レスポンス。サーバー側で使う。
    init(code: String, name: String, sector: String, market: String, result: MetricsResult) {
        schemaVersion = Api.financialsSchemaVersion
        self.code = code
        self.name = name
        self.sector = sector
        self.market = market
        currency = "JPY"
        unit = "百万円"
        years = (result.years ?? []).map { FinancialsYear($0) }
    }

    /// 公開契約レスポンス → 内部モデル（MetricsResult）。remote CLI が既存レンダラへ渡す。
    func toMetricsResult() -> MetricsResult {
        var result = MetricsResult.blank
        result.code = code
        result.years = years.map { $0.toYearEntry() }
        return result
    }

    /// 指定 docID の年度エントリの売上高（円）。public: 内訳取り込み（BltServerCore）が事業別内訳の分母
    /// （連結外部売上）を 財務取り込み の計算済み結果から再利用するために使う（自前で XBRL から
    /// 再抽出しない。重複ロジック回避）。`years[].sales` は `unit`（百万円）建てのため、内訳取り込み の
    /// 正規化器が期待する円単位へここで変換する。該当年度が無ければ nil。
    public func salesForDoc(_ docID: String) -> Double? {
        years.first { $0.docId == docID }?.sales.map { $0 * Financial.millionYen }
    }

    /// 当該 docID の年次エントリがあるか（売上の有無は問わない）。
    /// 内訳取り込み が「財務取り込み 未計算」と「計算済みだが売上抽出不能」を分けるために使う。
    public func hasDoc(_ docID: String) -> Bool {
        years.contains { $0.docId == docID }
    }

    /// 指定 docID の従業員数（全社合計・人）。Stage 6 の employees 軸が分母（全社合計）として
    /// 再利用するために使う（`salesForDoc` と同型、重複ロジック回避。2026-08-01 監査指摘対応）。
    /// `years[].employees` は `Int?` のためここで `Double` へ変換する。
    public func employeesForDoc(_ docID: String) -> Double? {
        years.first { $0.docId == docID }?.employees.map(Double.init)
    }

    /// 指定 docID の発行済普通株式数（期末残高・株）。財務諸表注記取り込み の `issued_shares` note_type 用。
    public func issuedSharesForDoc(_ docID: String) -> Double? {
        years.first { $0.docId == docID }?.issuedShares
    }

    /// 指定 docID の研究開発費（円、連結・全社合計）。Stage 6 の research_and_development 軸の
    /// 分母（全社合計）、および 財務諸表注記取り込み の `research_and_development` note_type の両方が再利用する。
    /// `years[].rd` は百万円建てのため円へ変換する。
    public func rdForDoc(_ docID: String) -> Double? {
        years.first { $0.docId == docID }?.rd.map { $0 * Financial.millionYen }
    }

    /// 指定 docID の設備投資額（円、設備投資等の概要優先）。財務諸表注記取り込み の
    /// `capital_expenditures_overview` note_type 用。
    public func capexForDoc(_ docID: String) -> Double? {
        years.first { $0.docId == docID }?.capex.map { $0 * Financial.millionYen }
    }

    /// 指定 docID の自己株式取得額（円）。財務諸表注記取り込み の `treasury_stock_acquisition` note_type 用。
    public func treasuryStockAcquisitionForDoc(_ docID: String) -> Double? {
        years.first { $0.docId == docID }?.buyback.map { $0 * Financial.millionYen }
    }

    /// 有価証券報告書未提出等、計算対象外だった企業のプレースホルダ（`years` 空）。
    /// public: 財務取り込み ingest（BltServerCore）が `.notApplicable` 判定時にこの行を保存し、
    /// 次回 ingest で highWater 一致のまま無駄な再計算を繰り返さないようにするために使う
    /// （読み取り経路 `loadStoredFinancials`/`loadStoredAnalysis` は `years` 空を検出し 404 を維持する。
    /// issue #86）。
    public static func notApplicablePlaceholder(code: String) -> FinancialsResponse {
        FinancialsResponse(
            schemaVersion: Api.financialsSchemaVersion, code: code, name: "", sector: "", market: "",
            currency: "JPY", unit: "百万円", years: [])
    }

    /// 格納済み `years` の件数。public: 財務取り込み read 経路（BltServerCore）が
    /// notApplicable プレースホルダ（`years` 空）を検出して 404 を維持するために使う（issue #86）。
    public var yearCount: Int { years.count }

    /// 全キーを含む JSON オブジェクト（years 各要素も null 補完する）。サーバー応答用。
    /// public: BltServerCore の 財務取り込み read 経路が格納済みレスポンスを JSON へ落とすために使う。
    public func jsonObject() -> [String: Any] {
        [
            "schema_version": schemaVersion,
            "code": code,
            "name": name,
            "sector": sector,
            "market": market,
            "currency": currency,
            "unit": unit,
            "years": years.map { $0.jsonObject() },
        ]
    }

    /// Summary（financials）応答用の全キー JSON オブジェクト（`years` 各要素は
    /// `analysisOnlyKeys` を除いた水準値のみ）。public: BltServerCore の financials read 経路が使う。
    public func summaryJsonObject() -> [String: Any] {
        [
            "schema_version": schemaVersion,
            "code": code,
            "name": name,
            "sector": sector,
            "market": market,
            "currency": currency,
            "unit": unit,
            "years": years.map { $0.summaryJsonObject() },
        ]
    }

    /// Waterfall（waterfall）応答用の全キー JSON オブジェクト。`years`（新しい順）を隣接ペアで走査し、
    /// 各年度に増減分解フィールド（④⑤ブロック含む）を付与する。呼び出し側は `trimmed(toYears:)` を
    /// 先に適用してから呼ぶこと（trim 後の集合内で前年差を計算するため。`FinancialsYear.jsonObject()`
    /// が保持する①②③の増減分解フィールドは ingest 時に計算済みで、trim 済みの集合とも整合している）。
    /// public: BltServerCore の waterfall read 経路が使う。
    public func analysisJsonObject() -> [String: Any] {
        [
            "schema_version": schemaVersion,
            "code": code,
            "name": name,
            "sector": sector,
            "market": market,
            "currency": currency,
            "unit": unit,
            "years": years.indices.map { i in
                years[i].analysisJsonObject(prior: i + 1 < years.count ? years[i + 1] : nil)
            },
        ]
    }

    /// years を新しい順の先頭 n 件に縮めたコピーを返す（n 以上ならそのまま）。
    /// 財務取り込み derived キャッシュは要求年数以上で格納し、read 時に要求年数へ縮める。
    ///
    /// ライブ計算経路は要求年数ちょうどの年度集合で waterfall を回すため、最古年は前年が無く
    /// 増減系フィールドが null になる（Waterfall.swift の各ループは k>=1 のみ設定）。DB 経路は
    /// 多めの年数で計算してから縮めるので、縮めた集合の最古年（より古い年を落とした結果）は
    /// 前年依存値を保持してしまう。両経路の出力を一致させるため、縮めて最古になった年の
    /// 前年依存フィールドを null へ戻す（実際に古い年を落とした＝n 未満に縮めた場合のみ）。
    public func trimmed(toYears n: Int) -> FinancialsResponse {
        guard n >= 0, years.count > n else { return self }
        var copy = self
        copy.years = Array(years.prefix(n))
        if n > 0 {
            copy.years[n - 1].clearPriorDependentMetrics()
        }
        return copy
    }
}

extension FinancialsYear {
    /// Waterfall.swift が「前年あり」のとき（ループ k>=1）だけ設定する増減系フィールドを null へ戻す。
    /// trim で最古になった年をライブ経路（最古年は前年なし＝null）と一致させるために使う。
    /// 対象は op 増減分解・ROIC 差分・ROE 差分の出力のみ（businessProfit/netMargin 等の
    /// 各年で設定される項目は対象外）。Waterfall.swift の k>=1 代入箇所と対応させて維持すること。
    mutating func clearPriorDependentMetrics() {
        businessProfitChange = nil
        salesChangeImpact = nil
        grossMarginChangeImpact = nil
        sgaChangeImpact = nil
        roicDelta = nil
        roicMarginEffect = nil
        roicTurnoverEffect = nil
        roeDelta = nil
        roeNetMarginEffect = nil
        roeAssetTurnoverEffect = nil
        roeLeverageEffect = nil
    }
}

// MARK: - 内部ヘルパー

/// Encodable を [String: Any] へ変換する（nil の Optional はキーごと省略される）。
private func encodeToDictionary(_ value: some Encodable) -> [String: Any] {
    guard let data = try? JSONEncoder().encode(value),
        let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        return [:]
    }
    return dict
}

// 全 Optional の内部モデルを「空（全 nil）」で生成する。
// メンバーワイズ init は全フィールド指定が必要なため、空 JSON のデコードで生成する
// （全フィールド Optional なので必ず成功する。リモート復元で必要分だけ後から詰める）。
extension RawData {
    static var blank: RawData {
        // swiftlint:disable:next force_try
        try! JSONDecoder().decode(RawData.self, from: Data("{}".utf8))
    }
}

extension CalculatedData {
    static var blank: CalculatedData {
        // swiftlint:disable:next force_try
        try! JSONDecoder().decode(CalculatedData.self, from: Data("{}".utf8))
    }
}

extension MetricsResult {
    static var blank: MetricsResult {
        // swiftlint:disable:next force_try
        try! JSONDecoder().decode(MetricsResult.self, from: Data("{}".utf8))
    }
}
