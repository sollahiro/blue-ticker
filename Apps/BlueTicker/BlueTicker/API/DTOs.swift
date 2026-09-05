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

struct FeedUpdatesResponse: Codable {
    var schemaVersion: Int
    var date: String
    var days: Int
    var items: [FeedUpdateItem]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case date, days, items
    }
}

struct FeedUpdateItem: Codable, Hashable, Identifiable {
    var code: String
    var name: String
    var docId: String
    var docType: String
    var docTypeLabel: String
    var fyEnd: String
    var submittedAt: String
    var iconURL: String?

    var id: String { docId }

    enum CodingKeys: String, CodingKey {
        case code, name
        case docId = "doc_id"
        case docType = "doc_type"
        case docTypeLabel = "doc_type_label"
        case fyEnd = "fy_end"
        case submittedAt = "submitted_at"
        case iconURL = "icon_url"
    }
}

struct FeedTrendResponse: Codable {
    var schemaVersion: Int
    var date: String
    var days: Int
    var items: [FeedTrendItem]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case date, days, items
    }
}

struct FeedTrendItem: Codable, Hashable, Identifiable {
    var code: String
    var name: String
    var count: Int
    var iconURL: String?

    var id: String { code }

    enum CodingKeys: String, CodingKey {
        case code, name, count
        case iconURL = "icon_url"
    }
}

struct CompanyNewsResponse: Codable {
    var schemaVersion: Int
    var date: String
    var code: String
    var name: String
    var query: String
    var items: [CompanyNewsItem]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case date, code, name, query, items
    }
}

struct CompanyNewsItem: Codable, Hashable, Identifiable {
    var title: String
    var url: String
    var source: String?
    var age: String?
    var publishedAt: String?
    var description: String?
    var thumbnailURL: String?

    var id: String { url }

    enum CodingKeys: String, CodingKey {
        case title, url, source, age, description
        case publishedAt = "published_at"
        case thumbnailURL = "thumbnail_url"
    }
}

struct FinancialsResponse: Codable {
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

/// 公開 JSON の手書き。Summary（`/financials`）は水準値、Waterfall（`/waterfall`）はそれに増減分解を足す。
/// Core の内部型はコピーしない。画面が読むキーだけ持つ。
struct FinancialsYear: Codable, Hashable, Identifiable {
    var fyEnd: String?
    var financialPeriod: String?
    var docId: String?

    var sales: Double?
    var grossProfit: Double?
    var grossProfitMargin: Double?
    var sga: Double?
    var operatingProfit: Double?
    var operatingMargin: Double?
    var netProfit: Double?
    var roic: Double?
    var roe: Double?
    var netDe: Double?
    var netCash: Double?
    var cfo: Double?
    var cfi: Double?
    var capex: Double?
    var totalAssets: Double?
    var currentAssets: Double?
    var nonCurrentAssets: Double?
    var currentLiabilities: Double?
    var netAssets: Double?

    var businessProfit: Double?
    var businessProfitMargin: Double?
    var businessProfitChange: Double?
    var salesChangeImpact: Double?
    var grossMarginChangeImpact: Double?
    var sgaChangeImpact: Double?
    var roicDelta: Double?
    var roicMarginEffect: Double?
    var roicTurnoverEffect: Double?
    var roeDelta: Double?
    var roeNetMarginEffect: Double?
    var roeAssetTurnoverEffect: Double?
    var roeLeverageEffect: Double?

    var id: String { fyEnd ?? docId ?? financialPeriod ?? "" }

    enum CodingKeys: String, CodingKey {
        case fyEnd = "fy_end"
        case financialPeriod = "financial_period"
        case docId = "doc_id"
        case sales
        case grossProfit = "gross_profit"
        case grossProfitMargin = "gross_profit_margin"
        case sga
        case operatingProfit = "operating_profit"
        case operatingMargin = "operating_margin"
        case netProfit = "net_profit"
        case roic, roe
        case netDe = "net_de"
        case netCash = "net_cash"
        case cfo
        case cfi
        case capex
        case totalAssets = "total_assets"
        case currentAssets = "current_assets"
        case nonCurrentAssets = "non_current_assets"
        case currentLiabilities = "current_liabilities"
        case netAssets = "net_assets"
        case businessProfit = "business_profit"
        case businessProfitMargin = "business_profit_margin"
        case businessProfitChange = "business_profit_change"
        case salesChangeImpact = "sales_change_impact"
        case grossMarginChangeImpact = "gross_margin_change_impact"
        case sgaChangeImpact = "sga_change_impact"
        case roicDelta = "roic_delta"
        case roicMarginEffect = "roic_margin_effect"
        case roicTurnoverEffect = "roic_turnover_effect"
        case roeDelta = "roe_delta"
        case roeNetMarginEffect = "roe_net_margin_effect"
        case roeAssetTurnoverEffect = "roe_asset_turnover_effect"
        case roeLeverageEffect = "roe_leverage_effect"
    }
}

struct APIErrorBody: Codable {
    var error: String?
    var status: Int?
}

enum APIClientError: LocalizedError {
    case badURL
    case http(status: Int, message: String)
    case decoding(Error)
    case transport(Error)

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "API の URL が不正です"
        case .http(_, let message):
            return message
        case .decoding:
            return "応答の形式を解釈できません"
        case .transport(let error):
            return error.localizedDescription
        }
    }
}
