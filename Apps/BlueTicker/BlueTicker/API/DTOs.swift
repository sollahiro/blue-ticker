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

struct FinancialsYear: Codable, Hashable, Identifiable {
    var fyEnd: String?
    var sales: Double?
    var operatingProfit: Double?
    var operatingMargin: Double?
    var netProfit: Double?
    var roic: Double?
    var roe: Double?
    var netDe: Double?
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

    var id: String { fyEnd ?? UUID().uuidString }

    enum CodingKeys: String, CodingKey {
        case fyEnd = "fy_end"
        case sales
        case operatingProfit = "operating_profit"
        case operatingMargin = "operating_margin"
        case netProfit = "net_profit"
        case roic, roe
        case netDe = "net_de"
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
