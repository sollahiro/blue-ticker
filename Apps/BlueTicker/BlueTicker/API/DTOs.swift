import Foundation

struct CompanyHit: Codable, Hashable, Identifiable {
    var code: String
    var name: String
    var sector: String?
    var market: String?
    var location: String?
    var iconURL: String?

    var id: String { code }

    enum CodingKeys: String, CodingKey {
        case code, name, sector, market, location
        case iconURL = "icon_url"
    }
}

struct FinancialsResponse: Codable {
    var schemaVersion: Int
    var code: String
    var name: String
    var sector: String
    var market: String
    /// 全年度が同じ通貨のときだけ値がある（混在は null）。年度ごとは `years[].currency`。
    var currency: String?
    /// キー → 単位コード（`currency_amount` は通貨の基本単位）。
    var units: [String: String]?
    var years: [FinancialsYear]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case code, name, sector, market, currency, units, years
    }
}

/// 公開 JSON の手書き。Summary（`/financials`）は水準値、Waterfall（`/waterfall`）はそれに増減分解を足す。
/// Core の内部型はコピーしない。画面が読むキーだけ持つ。
struct FinancialsYear: Codable, Hashable, Identifiable {
    var fyEnd: String?
    var financialPeriod: String?
    var docId: String?
    /// 金額の通貨（ISO 4217）。金額は通貨の基本単位（円なら円）。
    var currency: String?

    var sales: Double?
    var grossProfit: Double?
    var grossProfitMargin: Double?
    var sga: Double?
    var operatingProfit: Double?
    var operatingMargin: Double?
    var netProfit: Double?
    var roic: Double?
    var roe: Double?
    var nopatMargin: Double?
    var investedCapitalTurnover: Double?
    var netMargin: Double?
    var assetTurnover: Double?
    var financialLeverage: Double?
    var netDe: Double?
    var netCash: Double?
    var cashEquivalents: Double?
    var interestBearingDebt: Double?
    var cfo: Double?
    var cfi: Double?
    var capex: Double?
    var employees: Int?
    var totalAssets: Double?
    var currentAssets: Double?
    var nonCurrentAssets: Double?
    var currentLiabilities: Double?
    var netAssets: Double?
    /// 最新 FY の Summary 一株当たり当期純利益。単位は円/株。
    var eps: Double?
    /// 最新 FY の Summary 一株当たり純資産。単位は円/株。
    var bps: Double?

    var businessProfit: Double?
    var businessProfitMargin: Double?
    var businessProfitChange: Double?
    var salesChangeImpact: Double?
    var grossMarginChangeImpact: Double?
    var sgaChangeImpact: Double?

    /// 資金配分（Waterfall のみ）。CF の符号（収入が正、支出が負）。
    /// cfc（フリーCF）+ cff + cfFxEffect + cfOtherCashChange = cfCashChange。
    var cfc: Double?
    var cff: Double?
    var cfDebtChange: Double?
    var cfDividendsParent: Double?
    var cfBuyback: Double?
    var cfOtherFinancing: Double?
    var cfFxEffect: Double?
    var cfCashChange: Double?
    var cfOtherCashChange: Double?

    var id: String { fyEnd ?? docId ?? financialPeriod ?? "" }

    enum CodingKeys: String, CodingKey {
        case fyEnd = "fy_end"
        case financialPeriod = "financial_period"
        case docId = "doc_id"
        case currency
        case sales
        case grossProfit = "gross_profit"
        case grossProfitMargin = "gross_profit_margin"
        case sga
        case operatingProfit = "operating_profit"
        case operatingMargin = "operating_margin"
        case netProfit = "net_profit"
        case roic, roe
        case nopatMargin = "nopat_margin"
        case investedCapitalTurnover = "invested_capital_turnover"
        case netMargin = "net_margin"
        case assetTurnover = "asset_turnover"
        case financialLeverage = "financial_leverage"
        case netDe = "net_de"
        case netCash = "net_cash"
        case cashEquivalents = "cash_equivalents"
        case interestBearingDebt = "interest_bearing_debt"
        case cfo
        case cfi
        case capex
        case employees
        case totalAssets = "total_assets"
        case currentAssets = "current_assets"
        case nonCurrentAssets = "non_current_assets"
        case currentLiabilities = "current_liabilities"
        case netAssets = "net_assets"
        case eps
        case bps
        case businessProfit = "business_profit"
        case businessProfitMargin = "business_profit_margin"
        case businessProfitChange = "business_profit_change"
        case salesChangeImpact = "sales_change_impact"
        case grossMarginChangeImpact = "gross_margin_change_impact"
        case sgaChangeImpact = "sga_change_impact"
        case cfc, cff
        case cfDebtChange = "cf_debt_change"
        case cfDividendsParent = "cf_dividends_parent"
        case cfBuyback = "cf_buyback"
        case cfOtherFinancing = "cf_other_financing"
        case cfFxEffect = "cf_fx_effect"
        case cfCashChange = "cf_cash_change"
        case cfOtherCashChange = "cf_other_cash_change"
    }
}

struct CompanyOverviewResponse: Codable {
    var schemaVersion: Int
    var code: String
    var overview: String
    var docId: String?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case code, overview
        case docId = "doc_id"
    }
}

struct APIErrorBody: Codable {
    var error: String?
    var status: Int?
    /// 404 の理由（例: `single_segment_disclosed`）。内訳の「該当なし」応答にだけ付く。
    var reason: String?
}

enum APIClientError: LocalizedError {
    case badURL
    case http(status: Int, message: String)
    case decoding(Error)
    case transport(Error)
    case hapisUnavailable

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "API の URL が不正です"
        case .http(let status, let message):
            if status == 429 {
                return "アクセスが集中しています。少し待ってから再度お試しください"
            }
            return message
        case .decoding:
            return "応答の形式を解釈できません"
        case .transport(let error):
            return error.localizedDescription
        case .hapisUnavailable:
            return "一時的に更新できません"
        }
    }
}
