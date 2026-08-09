import Foundation

/// GET /v1/companies?q= の1件分。サーバー側 `companyJSON`（BltServerFacade.swift）と対応。
struct CompanySearchResult: Codable, Identifiable, Hashable {
    var code: String
    var name: String
    var sector: String
    var market: String
    var location: String
    var iconURL: URL? = nil

    var id: String { code }

    enum CodingKeys: String, CodingKey {
        case code, name, sector, market, location
        case iconURL = "icon_url"
    }
}
