// 半期財務データモデル

struct HalfPeriod: Codable {
    var label: String     // "24H1", "24H2", "24FY"
    var half: String?     // "H1", "H2", nil (FY のみ)
    var fyEnd: String?
    var yearEntry: YearEntry

    enum CodingKeys: String, CodingKey {
        case label; case half; case fyEnd = "fy_end"; case yearEntry = "year_entry"
    }
}
