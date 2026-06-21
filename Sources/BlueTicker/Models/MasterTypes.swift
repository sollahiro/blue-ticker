struct MasterStock: Codable {
    let code: String
    let coName: String
    let coNameUpper: String
    let coNameNormalized: String
    let s33nm: String
    let mktNm: String
    let location: String
    let s33: String
    let s17nm: String
    let s17: String

    // CSV の列名と対応させる CodingKeys
    enum CodingKeys: String, CodingKey {
        case code      = "Code"
        case coName    = "CoName"
        case coNameUpper       = "CoNameUpper"
        case coNameNormalized  = "CoNameNormalized"
        case s33nm     = "S33Nm"
        case mktNm     = "MktNm"
        case location  = "Location"
        case s33       = "S33"
        case s17nm     = "S17Nm"
        case s17       = "S17"
    }
}

struct StockSearchResult: Codable {
    let code: String
    let name: String
    let sector: String
    let market: String
    let location: String
}

struct SectorSummary: Codable {
    let code: String
    let name: String
    let count: Int
}
