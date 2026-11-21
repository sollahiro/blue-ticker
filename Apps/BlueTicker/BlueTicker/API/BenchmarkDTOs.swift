import Foundation

/// `GET /v1/benchmark/{group}`。業種グループの全社分の KPI（会社ごとに最新の有報）。
struct BenchmarkResponse: Codable {
    var schemaVersion: Int
    var industryGroup: String
    var companies: [BenchmarkCompany]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case industryGroup = "industry_group"
        case companies
    }
}

struct BenchmarkCompany: Codable, Hashable, Identifiable {
    var code: String
    var name: String
    /// 東証 33 業種名。
    var sector: String
    var iconURL: String?
    var docId: String?
    var fyEnd: String?
    /// KPI キー → 値。無い KPI はキーごと無い。
    var kpis: [String: BenchmarkKPI]
    var warnings: [String]?

    var id: String { code }

    /// 銘柄面へ渡す参照。
    var ref: CompanyRef {
        CompanyRef(code: code, name: name, sector: sector, iconURL: iconURL)
    }

    enum CodingKeys: String, CodingKey {
        case code, name, sector, kpis, warnings
        case iconURL = "icon_url"
        case docId = "doc_id"
        case fyEnd = "fy_end"
    }
}

struct BenchmarkKPI: Codable, Hashable {
    var value: Double
    /// `percent` / `currency_amount`（円）。
    var unit: String
    var periodBasis: String
    var scope: String

    enum CodingKeys: String, CodingKey {
        case value, unit, scope
        case periodBasis = "period_basis"
    }
}
