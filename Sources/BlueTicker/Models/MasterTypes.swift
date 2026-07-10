struct MasterStock: Codable {
    let code: String
    let coName: String
    let coNameUpper: String
    let coNameNormalized: String
    let s33nm: String
    let mktNm: String
    let location: String
    /// EDINET「提出者業種」の値。CSV に業種コード列が無いため、現状は業種名と同じ文字列が入る。
    let s33: String
    /// EDINET「提出者種別」の値（例: "内国法人・組合" / "外国法人・組合"）。
    let filerType: String

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
        case filerType = "FilerType"
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
