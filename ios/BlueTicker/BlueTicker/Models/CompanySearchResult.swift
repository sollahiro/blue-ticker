import Foundation

/// GET /v1/companies?q= の1件分。サーバー側 `companyJSON`（BltServerFacade.swift）と対応。
struct CompanySearchResult: Codable, Identifiable, Hashable {
    var code: String
    var name: String
    var sector: String
    var market: String
    var location: String

    var id: String { code }
}
